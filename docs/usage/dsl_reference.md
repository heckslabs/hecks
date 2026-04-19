# Hecks DSL Reference

Complete reference for the Bluebook domain definition language.

## Quick Start — A Complete Domain

This example shows every major DSL feature in one domain. Copy it as a starting point.

```ruby
Hecks.domain "Pizzas" do
  description "Pizza ordering domain"

  # --- Aggregates ---

  aggregate "Pizza" do
    description "A pizza with toppings on a menu"
    attribute :name, String
    attribute :description, String
    attribute :price, Float
    attribute :toppings, list_of("Topping")

    value_object "Topping" do
      description "A measured ingredient on a pizza"
      attribute :name, String
      attribute :amount, Integer
      invariant "amount must be positive" do
        amount > 0
      end
    end

    validation :name, presence: true
    validation :description, presence: true

    command "CreatePizza" do
      description "Add a new pizza to the menu"
      attribute :name, String
      attribute :description, String
      attribute :price, Float
    end

    command "AddTopping" do
      description "Add an ingredient to an existing pizza"
      reference_to "Pizza", validate: :exists
      attribute :name, String
      attribute :amount, Integer
    end

    query "ByDescription" do |desc|
      where(description: desc)
    end

    scope :affordable, price: 15.0

    specification "Premium" do |pizza|
      pizza.price > 20
    end

    invariant "price must be positive" do
      price > 0
    end

    port :admin do
      allow :find, :all, :create_pizza
    end
  end

  aggregate "Order" do
    description "A customer order for a pizza"
    attribute :customer_name, String
    attribute :items, list_of("OrderItem")
    reference_to "Pizza"

    attribute :status, String, default: "pending" do
      transition "CancelOrder" => "cancelled"
      transition "FulfillOrder" => "fulfilled", from: "pending"
    end

    value_object "OrderItem" do
      description "A line item with a quantity"
      attribute :quantity, Integer
      invariant "quantity must be positive" do
        quantity > 0
      end
    end

    validation :customer_name, presence: true

    command "PlaceOrder" do
      description "Place a new order"
      attribute :customer_name, String
      reference_to "Pizza", validate: :exists
      attribute :quantity, Integer
    end

    command "CancelOrder" do
      description "Cancel a pending order"
      reference_to "Order", validate: :exists
    end

    command "FulfillOrder" do
      description "Mark an order as fulfilled"
      reference_to "Order", validate: :exists
    end

    query "Pending" do
      where(status: "pending")
    end
  end

  # --- Cross-aggregate policy ---
  policy "NotifyKitchen" do
    on "PlacedOrder"
    trigger "PrepareIngredients"
    map pizza: :pizza, quantity: :servings
  end

  # --- Domain service ---
  service "TransferOrder" do
    attribute :order_id, String
    attribute :new_pizza_id, String
    coordinates "Order", "Pizza"
  end

  # --- Actors ---
  actor "Customer"
  actor "Admin", description: "Store manager"

  # --- Glossary ---
  glossary do
    prefer "customer", not: ["user", "client"]
    define "topping", as: "A measured ingredient applied to a pizza"
  end
end
```

Boot and use it:

```ruby
app = Hecks.boot(__dir__)

pizza = Pizza.create(name: "Margherita", description: "Classic", price: 12.0)
pizza.toppings.create(name: "Mozzarella", amount: 2)

order = Order.place(pizza: pizza, customer_name: "Alice", quantity: 3)
Order.pending  # => [order]

app.events.each { |e| puts e.class.name.split("::").last }
```

---

## DSL Keywords

### Domain

| Keyword | Purpose | Details |
|---------|---------|---------|
| `Hecks.domain "Name"` | Define a bounded context | [Domain](#domain-1) |
| `description` | Human-readable text | Available on every block |
| `version:` | Semver or CalVer | [Domain Versioning](domain_version.md) |
| `aggregate` | Define an aggregate root | [Aggregates](aggregate_definition.md) |
| `policy` | Cross-aggregate reactive policy | [Policies](domain_level_policies.md) |
| `service` | Coordinates multiple aggregates | [Services](domain_services.md) |
| `view` | Read model projection | [Views](vertical_slices.md) |
| `workflow` | Multi-step branching process | [Workflows](#workflow) |
| `saga` | Long-running compensating process | [Sagas](sagas.md) |
| `actor` | Role declaration | [Actors](#actors) |
| `glossary` | Ubiquitous language rules | [Glossary](glossary.md) |
| `world_concerns` | Ethical validation | [World Concerns](world_concerns.md) |
| `tenancy` | Multi-tenancy mode | `:row` or `:schema` |
| `domain_module` | Logical grouping | Namespace aggregates |
| `on_event` | Domain-level subscriber | Event handler block |
| `entry_point` | Autoload setup file | [Self-hosting](self-hosting.md) |

### Aggregate

| Keyword | Purpose | Details |
|---------|---------|---------|
| `attribute` | Data field | [Types](#types) |
| `list_of` | Collection attribute | `attribute :items, list_of("Item")` |
| `reference_to` | Relationship to another aggregate | [References](#references) |
| `value_object` | Immutable child object | [Value Objects](#value-objects) |
| `entity` | Mutable child with identity | [Entities](#entities) |
| `command` | Intent to change state | [Commands](#commands) |
| `query` | Named query with logic block | [Queries](aggregate_definition.md) |
| `scope` | Named filter (hash or lambda) | [Scopes](aggregate_definition.md) |
| `specification` | Named boolean predicate | [Specifications](#specifications) |
| `policy` | Reactive policy on this aggregate | [Policies](domain_level_policies.md) |
| `validation` | Field-level validation rule | [Validations](#validations) |
| `invariant` | Aggregate-level business rule | [Invariants](#invariants) |
| `lifecycle` / `transition` | State machine | [Lifecycle](#lifecycle) |
| `port` | Access control per role | [Architecture Decisions](architecture_decisions.md) |
| `on_event` | Event subscriber | Event handler block |
| `repository` | Repository interface methods | `:find, :all, :save, :delete` |
| `factory` | Named construction pattern | Alternative to commands |
| `event` | Explicit event (not inferred) | [Events](emits.md) |
| `computed` | Derived attribute (not stored) | [Computed](computed_attributes.md) |
| `identity` | Natural key declaration | [Identity](#identity) |
| `description` | Human-readable text | Used by generators and docs |
| `namespace` | Module nesting path | Self-hosting metadata |
| `inherits` | Superclass declaration | Self-hosting metadata |
| `includes` | Mixin module | Self-hosting metadata |

### Command

| Keyword | Purpose | Details |
|---------|---------|---------|
| `attribute` | Input parameter | [Types](#types) |
| `reference_to` | Reference input | Self-ref = update command |
| `description` | Human-readable text | Used by generators and docs |
| `method_name` | Override generated method name | `method_name "place"` |
| `guarded_by` | Guard policy reference | [Policies](domain_level_policies.md) |
| `sets` | Static field assignments | `sets status: "pending"` |
| `actor` | Role that can issue command | [Actors](#actors) |
| `read_model` | Data dependency | Documentation only |
| `external` | External system dependency | Documentation only |
| `precondition` | Pre-execution check | Block with message |
| `postcondition` | Post-execution check | Block with message |
| `handler` | Custom handler block | Overrides default behavior |
| `call` | Inline call body | Lightweight logic |
| `given` | Precondition in UL | [Given/Then](#given--then--declarative-behavior) |
| `then_set` | Declarative state mutation | [Given/Then](#given--then--declarative-behavior) |
| `then_toggle` | Toggle boolean field | [Given/Then](#given--then--declarative-behavior) |
| `emits` | Explicit event name | [Emits](emits.md) |

### Value Object / Entity

| Keyword | Purpose |
|---------|---------|
| `attribute` | Data field |
| `description` | Human-readable text |
| `invariant` | Business rule |

---

## Domain {#domain-1}

A domain is a bounded context with its own language, rules, and data.

```ruby
Hecks.domain "Pizzas" do
  description "Core pizza operations"
  # ...
end

Hecks.domain "Banking", version: "2026.04.01.1" do
  # CalVer versioning
end
```

See [Domain Versioning](domain_version.md) for version format details.

---

## Types

| Type | Aliases |
|------|---------|
| `String` | `:string`, `:str` |
| `Integer` | `:integer`, `:int` |
| `Float` | `:float` |
| `TrueClass` | `:boolean`, `:bool` |
| `Symbol` | `:symbol` |
| `Array` | `:array` |
| `Hash` | `:hash` |
| `Date` | `:date` |
| `DateTime` | `:datetime` |

Attribute options: `default:`, `enum:`, `pii:`.

```ruby
attribute :status, String, default: "draft"
attribute :role, String, enum: ["admin", "user"]
attribute :email, String, pii: true
attribute :toppings, list_of("Topping")
```

---

## Commands

Commands are intents to change state. Each infers a domain event (`CreatePizza` -> `CreatedPizza`). A self-referencing `reference_to` makes it an update; without one, it's a create.

```ruby
command "PlaceOrder" do
  description "Place a new order for a pizza"
  attribute :customer_name, String
  reference_to "Pizza", validate: :exists
  attribute :quantity, Integer
  guarded_by "MustBeAuthenticated"
  sets status: "pending"
  actor "Customer"
  method_name "place"
end
```

See [Emits](emits.md) for explicit event names.

### Given / Then — Declarative Behavior

Commands can declare preconditions (`given`) and state mutations (`then_set`) in pure ubiquitous language. No Ruby handlers — the runtime interprets them, and generators transpile them to any target.

```ruby
command "PlaceOrder" do
  description "Place a new order for a pizza"
  attribute :customer_name, String
  reference_to "Pizza", validate: :exists
  attribute :quantity, Integer

  given { quantity > 0 }
  given("customer must have name") { customer_name.length > 0 }

  then_set :status, to: "placed"
  then_set :items, append: { pizza: :pizza, quantity: :quantity }
  then_set :order_count, increment: 1
end
```

**`given`** — Precondition checked before execution. The block is captured as source text, not a Proc. Fails the command if false.

```ruby
given { toppings.size < 10 }
given("must be pending") { status == "pending" }
```

**`then_set`** — Declarative state mutation applied after preconditions pass.

| Operation | Syntax | Effect |
|-----------|--------|--------|
| Set | `then_set :field, to: value` | Assign value (literal or `:attribute_ref`) |
| Append | `then_set :field, append: value` | Add to list |
| Increment | `then_set :field, increment: n` | Add n to numeric field |
| Decrement | `then_set :field, decrement: n` | Subtract n from numeric field |

**`then_toggle`** — Toggle a boolean string field between `"true"` and `"false"`.

```ruby
then_toggle :sidebar_collapsed
```

Values can reference command attributes by symbol:

```ruby
then_set :name, to: :name          # copies from command input
then_set :status, to: "active"     # literal value
then_set :items, append: { name: :name, amount: :amount }  # compound
```

When `given`/`then_set` are present, the runtime uses `HecksalInterpreter` instead of a handler block. This keeps domain logic pure and projectable.

---

## References

Aggregates reference each other by identity, not containment.

```ruby
reference_to "Pizza"                           # name defaults to :pizza
reference_to "Team", as: :home_team            # explicit alias (canonical)
reference_to "Billing::Invoice"                # cross-domain
```

The `as:` kwarg is the canonical alias form. Legacy `role: :name` and
the trailing-symbol shorthand `reference_to(X) :name` are also accepted
by both parsers, but `as:` is preferred for new bluebooks.

See [Cross-Domain References](cross_domain_references.md).

---

## Value Objects

Immutable, no identity. Compared by value.

```ruby
value_object "Topping" do
  description "A measured ingredient"
  attribute :name, String
  attribute :amount, Integer
  invariant "amount must be positive" do
    amount > 0
  end
end
```

---

## Entities

Mutable children with identity, owned by the aggregate.

```ruby
entity "LedgerEntry" do
  description "A single accounting entry"
  attribute :amount, Float
  attribute :description, String
end
```

---

## Lifecycle

State machine on a single attribute. The runtime enforces transitions.

```ruby
attribute :status, String, default: "draft" do
  transition "Submit" => "pending"
  transition "Approve" => "published", from: "pending"
  transition "Archive" => "archived", from: ["draft", "published"]
end
```

Generated predicates: `post.draft?`, `post.published?`.

---

## Validations

Field-level checks.

```ruby
validation :name, presence: true
validation :email, presence: true, type: String, uniqueness: true
```

---

## Invariants

Aggregate-level business rules checked after every state change.

```ruby
invariant "price must be positive" do
  price > 0
end
```

---

## Specifications

Named boolean predicates for filtering, branching, or validation.

```ruby
specification "HighRisk" do |loan|
  loan.principal > 50_000
end
```

Used in workflows: `when_spec("HighRisk") { step "ManualReview" }`.

---

## Policies

Reactive policies listen for events and trigger commands.

```ruby
policy "NotifyKitchen" do
  on "PlacedOrder"
  trigger "PrepareIngredients"
  async true
  map pizza: :pizza, quantity: :servings
  condition { |event| event.quantity > 5 }
end
```

Guard policies run before commands: `guarded_by "MustBeAdmin"`.

See [Domain-Level Policies](domain_level_policies.md) and [Policy Conditions](policy_conditions.md).

---

## Computed Attributes

Derived values — not stored, calculated from other attributes.

```ruby
computed :lot_size do
  area / 43560.0
end
```

See [Computed Attributes](computed_attributes.md).

---

## Identity

Natural key for human-meaningful lookups alongside UUID.

```ruby
aggregate "TeamCycle" do
  attribute :team, String
  attribute :start_date, Date
  identity :team, :start_date
end
```

---

## Glossary

Enforces ubiquitous language. Warns when banned terms appear.

```ruby
glossary do
  define "aggregate", as: "A cluster of domain objects treated as a unit"
  prefer "customer", not: ["user", "client"]
end
```

See [Glossary](glossary.md).

---

## Sagas

Long-running cross-aggregate coordination with compensation.

```ruby
saga "OrderFulfillment" do
  step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
  step "ChargePayment",    on_success: "ShipOrder",     on_failure: "RefundReservation"
  step "ShipOrder"
  compensation "ReleaseInventory"
  compensation "RefundPayment"
end
```

See [Sagas](sagas.md).

---

## Booting

```ruby
# Standalone
app = Hecks.boot(__dir__)

# With SQL
app = Hecks.boot(__dir__, adapter: :sqlite)

# Rails
Hecks.configure do |config|
  config.domain_path = Rails.root.join("app/domain")
end
```

See [Rails Integration](hecks_on_rails.md) and [SQL Adapter](sql_adapter.md).

---

## Adapters

Adapters wire real behavior into generated command ports.

```ruby
module MyAdapter
  def self.reset(command:, app:)
    app.event_bus.clear
  end
end

app.adapt("TestHelper", MyAdapter)
app.run("Reset")  # calls MyAdapter.reset
```

Built-in: `Hecks::Adapters::TestHelperAdapter`, `Hecks::Adapters::EventBusAdapter`.

---

## Example Generator

Generates a documented example app from domain IR. Comments come from `description` metadata.

```ruby
require "hecks/generators/docs/example_generator"

domain = Hecks::Chapters::Spec.definition
gen = Hecks::Generators::ExampleGenerator.new(domain, aggregates: ["Pizza", "Order"])
files = gen.generate
# => { "example.rb" => "...", "SpecBluebook" => "...", "SpecHecksagon" => "..." }
```

---

## Shorthand Syntax

Inside aggregate blocks, bare names become attributes and PascalCase names become value objects:

```ruby
aggregate "Pizza" do
  name String                    # attribute :name, String
  price Float                    # attribute :price, Float

  Topping do                     # value_object "Topping" do
    name String
    amount Integer
  end

  create do                      # command "CreatePizza" do
    name String
    price Float
  end
end
```

At domain level, PascalCase names with blocks become aggregates:

```ruby
Hecks.domain "Pizzas" do
  Pizza do
    attribute :name, String
  end
end
```

---

## Further Reading

- [Aggregate Definition](aggregate_definition.md) — full aggregate DSL
- [Architecture Tour](architecture_tour.md) — how it all fits together
- [Connections](connections.md) — persistence and middleware extensions
- [Self-Hosting](self-hosting.md) — Hecks generates itself
- [Hecksagon DSL](hecksagon_dsl.md) — capabilities and cross-cutting concerns
- [CLI Reference](cli_tree.md) — command-line tools
- [World Concerns](world_concerns.md) — ethical validation
- [Event Sourcing](event_sourcing.md) — event-sourced aggregates
- [Bubble Contexts](bubble_contexts.md) — legacy system integration
