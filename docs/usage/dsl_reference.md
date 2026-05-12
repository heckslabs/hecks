# Hecks DSL Reference

Complete reference for the Bluebook domain definition language.

## Quick Start

```ruby
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, PizzaName               # typed VO — no primitive envy
    attribute :toppings, list_of(Topping)    # list_of required for collections

    value_object "PizzaName" do              # VO declared inside aggregate
      attribute :value, String
    end
    value_object "Topping" do
      attribute :name, String
      attribute :amount, Integer
      invariant "amount positive" do amount > 0 end
    end

    command "CreatePizza" do                 # no self-ref ⇒ create
      attribute :name, PizzaName
    end
    command "AddTopping" do                  # self-ref ⇒ update
      reference_to Pizza, validate: :exists
      attribute :name, String
      attribute :amount, Integer
    end

    query "ByName" do |name|
      where(name: name)
    end
  end
end
```

Dispatched as `pizzas::pizza::Pizza::CreatePizza` /
`pizzas::pizza::Pizza::by_name` (see [Bus Phrase](#bus-phrase)).

---

## DSL Keywords

- **Domain:** `Hecks.domain`, `description`, `version:`, `aggregate`,
  `policy`, `service`, `view`, `workflow`, `saga`, `actor`, `glossary`,
  `world_concerns`, `tenancy`, `domain_module`, `on_event`,
  `entry_point`.
- **Aggregate:** `attribute`, `list_of`, `reference_to`, `value_object`,
  `entity`, `command`, `query`, `scope`, `specification`, `policy`,
  `validation`, `invariant`, `lifecycle` / `transition`, `port`,
  `on_event`, `repository`, `factory`, `event`, `computed`, `identity`,
  `description`, `namespace`, `inherits`, `includes`.
- **Command:** `attribute`, `reference_to`, `description`,
  `method_name`, `guarded_by`, `sets`, `actor`, `role` (i483 typed),
  `read_model`, `external`, `precondition`, `postcondition`, `handler`,
  `call`, `given`, `then_set`, `then_toggle`, `emits`.
- **Value object / Entity:** `attribute`, `description`, `invariant`.

---

## Domain {#domain-1}

A domain is a bounded context with its own language, rules, and data.

```ruby
Hecks.domain "Pizzas" do
  description "Core pizza operations"
end

Hecks.domain "Banking", version: "2026.04.01.1" do
  # CalVer versioning — see domain_version.md
end
```

---

## Attributes

```ruby
attribute :name, Type, **options
```

Type may be a typed VO (`PizzaName`), a primitive (`String`, `Integer`
— see no-primitive-envy below), a symbol shorthand (`:string`, `:int`,
`:bool`, `:date`, `:datetime`, `:array`, `:hash`), or a list wrapper
(`list_of(X)`). Options pass through (`default:`, `enum:`, `pii:`).

### Collections must be explicit (2026-05-12)

`list_of(X)` is the **only** way to declare a list-shaped attribute.
The plural-name auto-list heuristic (`attribute :foos, Foo` →
`list_of(Foo)`) was retired in both the Ruby DSL
(`attribute_collector.rb`) and the Rust line-scanner
(`parse_blocks.rs`) — the two used to disagree on scalars ending in
`s` (e.g. `total_edits`). Bare `Array` / `Hash` are also scalar.

```ruby
attribute :toppings, list_of("Topping")  # list
attribute :total_edits, Integer          # scalar, plural name notwithstanding
```

### No primitive envy at the surface

The `no_primitive_envy` validator rule (commit `7a3c66d0`, 2026-05-09)
fails any aggregate or command attribute whose type is a bare primitive
(`String`, `Integer`, `Float`, `Boolean`, `Date`, `DateTime`, `JSON`).
Primitives live **inside** `value_object` bodies ; the aggregate /
command surface speaks in typed domain concepts.

```ruby
aggregate "Pizza" do
  attribute :name, PizzaName         # typed VO — passes
  # attribute :name, String          # fails no_primitive_envy
  value_object "PizzaName" do
    attribute :value, String         # primitive lives here, inside the VO
  end
end
```

---

## Commands

Commands are intents to change state. Each infers a domain event
(`CreatePizza` → `CreatedPizza`). A self-referencing `reference_to`
makes it an update ; without one, it's a create.

```ruby
command "PlaceOrder" do
  attribute :customer_name, CustomerName
  reference_to Pizza, validate: :exists
  attribute :quantity, Quantity
  guarded_by "MustBeAuthenticated"
  sets status: "pending"
  actor "Customer"
  method_name "place"
end
```

See [Emits](emits.md) for explicit event names.

### Given / Then — Declarative Behavior

Commands can declare preconditions (`given`) and state mutations
(`then_set` / `then_toggle`) in pure ubiquitous language. No Ruby
handlers — `HecksalInterpreter` runs them at the runtime, and
generators transpile them to any target.

```ruby
command "PlaceOrder" do
  reference_to Pizza, validate: :exists
  attribute :quantity, Quantity

  given { quantity > 0 }
  given("must be pending") { status == "pending" }

  then_set :status, to: "placed"
  then_set :items, append: { pizza: :pizza, quantity: :quantity }
  then_set :order_count, increment: 1
end
```

`given` captures block source text (not a Proc). Planner-friendly
shapes: equality, boolean, numeric inequality, list size
(`.size` / `.any?` / `.empty?`), cross-attribute. Opaque prose givens
generate skipped tests — rework as a boolean attr + producing command.

`then_set` operations: `to:` (assign), `append:` (push), `increment:` /
`decrement:`. Strings MUST use `to: "..."` ; positional form is for
bool / number / symbol literals only (parity with the Rust
line-scanner). `then_toggle :field` flips between `"true"` and
`"false"`. Values may reference command attrs by symbol (`to: :name`).

---

## Roles and Agents

> **Status — shape locked, parser pending (i483).** The typed form
> parses but isn't lifted into the IR yet ; the legacy string form
> still drives runtime behavior.

```ruby
command "Add"     do role "Caller"                       end  # legacy
command "Add"     do role Role, as: Agent                end  # typed (i483)
command "Compile" do role Role, as: Agent, kind: "system" end  # narrow
```

`Role` is the framework `Role` aggregate ; `Agent` is the alias for
the role-bearer. `kind:` filters by Agent kind (`"human"`, `"system"`,
`"daemon"`, `"bot"`, `"ai"`). The originating Agent flows through
policy cascades unless re-attributed (i481).

---

## References

Aggregates reference each other by identity, not containment.

```ruby
reference_to "Pizza"                # name defaults to :pizza
reference_to "Team", as: :home_team # explicit alias (canonical)
reference_to "Billing::Invoice"     # cross-domain
```

`as:` is the canonical alias form. Legacy `role: :name` and the
trailing-symbol shorthand `reference_to(X) :name` are also accepted,
but `as:` is preferred.

### Self-reference — the update-command convention

A command's `reference_to` whose target is the enclosing aggregate
makes the command an **update**. The reference's attribute name
defaults to `snake_case(AggregateName)` (`to_snake_case(&target)` in
`parse_blocks.rs`):

```ruby
aggregate "Pizza" do
  command "AddTopping" do
    reference_to Pizza, validate: :exists       # attribute name → :pizza
    attribute :name, String
    attribute :amount, Integer
  end
end

AddTopping.new(pizza: pizza_id, name: "...", amount: 2).call
```

For two references to the same aggregate (e.g. transfer source +
destination), use `as:` to disambiguate; otherwise both collapse to
the bare snake_case form and the IR is ambiguous (i526):

```ruby
command "Transfer" do
  reference_to Account, as: :source
  reference_to Account, as: :destination
end
```

A sidequest is in flight for `id=<value>` to work universally as a
self-reference kwarg alongside `pizza: pizza_id`.

See [Cross-Domain References](cross_domain_references.md).

---

## Bus Phrase

Every dispatch crosses the bus as a **four-segment phrase** — the
canonical addressing form from `command_bus.hecksagon`, emitted by the
`:codegen` adapter family (i528). HTTP, CLI, and WASM realizations all
dispatch through the same phrase.

```
app::domain::Aggregate::Command       # commands  — PascalCase end-to-end
app::domain::Aggregate::query_name    # queries   — snake_case query name
```

`app` and `domain` are kebab-case (filesystem layout); `Aggregate` and
`Command` are PascalCase; query names are snake_case on the wire even
though they're declared PascalCase in the bluebook.

The Ruby command-class emitter renders idiomatic shells (kebab → Pascal
for module nesting):

```ruby
BinBuddy::Notifications::WaveGoodbye.new(name: "Alice").call
# → Storehouse.route("bin-buddy::notifications::Greeter::WaveGoodbye",
#                    name: "Alice")
```

---

## Value Objects

Immutable, no identity. Compared by value.

```ruby
value_object "Topping" do
  attribute :name, String
  attribute :amount, Integer
  invariant "amount positive" do amount > 0 end
end
```

### Placement — inside the aggregate only

`value_object` is declared **inside the aggregate body that owns it**.
Bluebook-level (domain-level) VOs are forbidden ; every VO belongs to
exactly one aggregate. Duplication across aggregates is intentional
and fine — `Pizza::Name` and `Order::Name` are separate types, free
to diverge later without coupling.

```ruby
aggregate "Pizza" do
  value_object "Name" do attribute :value, String end  # Pizza::Name
end

aggregate "Order" do
  value_object "Name" do attribute :value, String end  # Order::Name
end
```

This pairs with `no_primitive_envy` (see [Attributes](#attributes)) :
the validator rejects bare primitives on the aggregate surface ; the
VO is where primitives live.

---

## Entities

Mutable children with identity, owned by the aggregate.

```ruby
entity "LedgerEntry" do
  attribute :amount, Money
  attribute :description, EntryDescription
end
```

---

## Queries

Named read-side projections inside an aggregate. Body is one or more
`where(...)` clauses. Block params (`do |desc|`) become implicit String
attributes that `where` references by symbol.

```ruby
query "Pending" do
  where(status: "pending")
end

query "ByDescription" do |desc|
  where(description: desc)
end
```

Supported inside the block:

- `where(field: value)` — equality (hash form)
- `where(field: { gt: 5 })` — comparator hash (`lt`, `lte`, `gt`, `gte`, `ne`)
- `order_by :field` / `order_by :field, :desc`
- `limit 10` / `limit :max`

Query names are PascalCase in the bluebook; on the wire they dispatch
in snake_case form: `app::domain::Aggregate::query_name`
(see [Bus Phrase](#bus-phrase)).

Cross-aggregate sweeps reference a query via the dotted source path
in a policy's `dispatch ... for_each:` clause:

```ruby
dispatch "Sweeper.Tick",
  for_each: { from: "Aggregate.query_name" }
```

Both 2-part (`Aggregate.query_name`) and 3-part
(`Context.Aggregate.query_name`) forms are accepted ; the 3-part form
disambiguates when multiple bluebooks share an aggregate name.

---

## Lifecycle

State machine on a single attribute. Runtime enforces transitions.
Generated predicates: `post.draft?`, `post.published?`.

```ruby
attribute :status, String, default: "draft" do
  transition "Submit"  => "pending"
  transition "Approve" => "published", from: "pending"
  transition "Archive" => "archived",  from: ["draft", "published"]
end
```

---

## Validations, Invariants, Specifications

Field-level checks, aggregate-level rules (run after every state
change), named predicates (compose into workflows via
`when_spec("HighRisk") { step "ManualReview" }`).

```ruby
validation :name,  presence: true
validation :email, presence: true, uniqueness: true
invariant "price positive" do price > 0 end
specification "HighRisk" do |loan| loan.principal > 50_000 end
```

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

Guard policies run before commands: `guarded_by "MustBeAdmin"`. See
[Domain-Level Policies](domain_level_policies.md) and
[Policy Conditions](policy_conditions.md).

---

## Computed Attributes, Identity, Glossary

Derived values, natural keys, ubiquitous-language rules. See
[Computed Attributes](computed_attributes.md), [Glossary](glossary.md).

```ruby
computed :lot_size do area / 43560.0 end

aggregate "TeamCycle" do
  attribute :team, TeamName
  attribute :start_date, Date
  identity :team, :start_date              # natural key alongside UUID
end

glossary do
  prefer "customer", not: ["user", "client"]
  define "aggregate", as: "A cluster of domain objects treated as a unit"
end
```

---

## Sagas

Long-running cross-aggregate coordination with compensation. See [Sagas](sagas.md).

```ruby
saga "OrderFulfillment" do
  step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
  step "ChargePayment",    on_success: "ShipOrder"
  compensation "ReleaseInventory"
end
```

---

## Booting and Adapters

```ruby
app = Hecks.boot(__dir__)                   # standalone
app = Hecks.boot(__dir__, adapter: :sqlite) # with SQL
Hecks.configure { |c| c.domain_path = ... } # Rails

app.adapt("TestHelper", MyAdapter)          # wire real behavior
app.run("Reset")                            # → MyAdapter.reset(command:, app:)
```

See [Rails Integration](hecks_on_rails.md), [SQL Adapter](sql_adapter.md).

---

## Shorthand Syntax

Inside aggregate blocks, bare names become attributes ; PascalCase +
block becomes a value object ; `create do ... end` becomes
`command "CreateAggregate"`. At domain level, PascalCase + block
becomes an aggregate.

```ruby
aggregate "Pizza" do
  name String                  # attribute :name, String
  Topping do                   # value_object "Topping"
    name String
    amount Integer
  end
  create do                    # command "CreatePizza"
    name String
  end
end
```

---

## Further Reading

[Aggregate Definition](aggregate_definition.md) ·
[Architecture Tour](architecture_tour.md) ·
[Connections](connections.md) ·
[Self-Hosting](self-hosting.md) ·
[Hecksagon DSL](hecksagon_dsl.md) ·
[CLI Reference](cli_tree.md) ·
[World Concerns](world_concerns.md) ·
[Event Sourcing](event_sourcing.md) ·
[Bubble Contexts](bubble_contexts.md)
