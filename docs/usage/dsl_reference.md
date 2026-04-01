# Hecks DSL Reference

> Generated from Hecks v2026.03.31.13

Complete reference for the Bluebook domain definition language.

## Domain

A domain is a bounded context — a self-contained area of your business with its own language, rules, and data. In DDD, you split a system into domains to keep each part focused and decoupled. A pizza shop has a "Pizzas" domain; a bank has "Accounts", "Loans", and "Transfers" domains. Each domain compiles independently into its own gem, runtime, and persistence layer.

Everything in Hecks lives inside a `Hecks.domain` block:

```ruby
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    # ...
  end
end
```

You may optionally declare a version with the `version:` kwarg. Both semver
and CalVer are supported; invalid strings raise `Hecks::InvalidDomainVersion`
immediately.

```ruby
Hecks.domain "Banking", version: "2.1.0" do
  # ...
end

Hecks.domain "Banking", version: "2026.04.01.1" do  # CalVer
  # ...
end
```

The version is accessible on the domain IR (`domain.version`), the loaded
module (`BankingDomain.version`), the generated gemspec, and the Go server
comment header. See [Domain Versioning](domain_version.md) for details.

### Domain-level methods

At the domain level you can declare aggregates, cross-aggregate policies, services, read models, workflows, actors, tenancy, and glossary rules:

```ruby
Hecks.domain "Banking" do
  aggregate "Account" do ... end

  # Cross-aggregate reactive policies
  policy "DisburseFunds" do
    on "IssuedLoan"
    trigger "Deposit"
    map principal: :amount
  end

  # Domain services (coordinate multiple aggregates)
  service "TransferMoney" do
    attribute :source_id, String
    attribute :dest_id, String
    attribute :amount, Float
    coordinates "Account", "Ledger"
    call do
      dispatch("Withdraw", account_id: source_id, amount: amount)
      dispatch("Deposit", account_id: dest_id, amount: amount)
    end
  end

  # Read model projections
  view "OrderSummary" do
    project("PlacedOrder") { |event, state| state.merge(total: event.quantity) }
  end

  # Workflows with branching
  workflow "LoanApproval" do
    step "ScoreLoan", score: :principal
    branch do
      when_spec("HighRisk") { step "ReviewLoan" }
      otherwise { step "ApproveLoan" }
    end
  end

  # Scheduled workflows
  workflow "OverdueCheck" do
    schedule "daily"
    step "ProcessOverdue" do
      find "Loan", spec: :overdue
      trigger "MarkDelinquent"
    end
  end

  # Actors
  actor "Customer"
  actor "Admin", description: "System administrator"

  # Multi-tenancy
  tenancy :row

  # Ubiquitous language enforcement
  glossary do
    prefer "stakeholder", not: ["user", "person"]
  end

  # Long-running cross-aggregate coordination
  saga "OrderFulfillment" do
    step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
    step "ChargePayment",    on_success: "ShipOrder",     on_failure: "RefundReservation"
    step "ShipOrder"
    compensation "ReleaseInventory"
    compensation "RefundPayment"
  end

  # Logical grouping
  domain_module "PolicyManagement" do
    aggregate "GovernancePolicy" do ... end
  end

  # Domain-level event subscriber
  on_event "CreatedPizza" do |event|
    puts event.name
  end
end
```

### Implicit syntax

PascalCase names with blocks become aggregates:

```ruby
Hecks.domain "Pizzas" do
  Pizza do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end
```

---

## Glossary

The glossary enforces ubiquitous language — the shared vocabulary your team uses. It warns when banned terms appear in attribute names, command names, or event names.

```ruby
Hecks.domain "Banking" do
  glossary do
    prefer "customer", not: ["user", "client"]
    prefer "account",  not: ["wallet", "fund"]
  end
end
```

When a banned term is detected, the compiler emits a warning: `"Use 'customer', not 'user' (found in attribute 'user_name')"`.

Multiple `prefer` rules can be declared in the same block:

```ruby
glossary do
  prefer "invoice",   not: ["bill", "receipt"]
  prefer "customer",  not: ["user", "client", "buyer"]
  prefer "shipment",  not: ["delivery", "parcel"]
end
```

---

## Saga

A saga coordinates a long-running process that spans multiple aggregates and commands. Use sagas when a single business operation requires several sequential steps — and each step may need to be undone if a later step fails.

Unlike a workflow (which branches based on specification predicates), a saga defines explicit success and failure transitions between named commands.

```ruby
Hecks.domain "Fulfillment" do
  saga "OrderFulfillment" do
    step "ReserveInventory", on_success: "ChargePayment", on_failure: "CancelOrder"
    step "ChargePayment",    on_success: "ShipOrder",     on_failure: "RefundReservation"
    step "ShipOrder"
    compensation "ReleaseInventory"
    compensation "RefundPayment"
  end
end
```

### step

```ruby
step "CommandName", on_success: "NextCommand", on_failure: "RollbackCommand"
```

- `on_success:` — the command to trigger when this step completes successfully
- `on_failure:` — the command to trigger when this step raises an error

Both options are optional. A step without `on_success` is the terminal step.

### compensation

```ruby
compensation "CommandName"
```

Registers a rollback command. Compensations are collected in declaration order and run in reverse if the saga must unwind. Each compensation should undo the effects of its corresponding step.

Saga definitions are stored in the domain IR and available via `domain.sagas`. See [Sagas](sagas.md) for a full walkthrough.

---

## Aggregate

An aggregate is a cluster of domain objects treated as a single unit for data changes. It has a root entity (the aggregate itself), owns its value objects and entities, and enforces its own invariants. Every write goes through a command on the aggregate — you never modify child objects directly.

Aggregates are the consistency boundary: everything inside one is guaranteed to be consistent after each command. References between aggregates are loose — they point to each other by identity, not by containment.

```ruby
aggregate "Pizza" do
  # Attributes
  attribute :name, String
  attribute :description, String
  attribute :price, Float
  attribute :active, :boolean
  attribute :metadata, Hash
  attribute :toppings, list_of("Topping")
  attribute :status, String, default: "draft"
  attribute :category, String, enum: ["classic", "specialty", "seasonal"]
  attribute :email, String, pii: true

  # References (relationships to other aggregates)
  reference_to "Restaurant"
  reference_to "Team", role: "home_team"      # explicit role
  reference_to "Billing::Invoice"             # cross-domain

  # Value objects (immutable, no identity)
  value_object "Topping" do
    attribute :name, String
    attribute :amount, Integer
    invariant "amount must be positive" do
      amount > 0
    end
  end

  # Entities (mutable, with identity)
  entity "LedgerEntry" do
    attribute :amount, Float
    attribute :description, String
  end

  # Commands
  command "CreatePizza" do
    attribute :name, String
    attribute :description, String
  end

  # Validations
  validation :name, presence: true
  validation :email, presence: true, type: String, uniqueness: true

  # Invariants
  invariant "price must be positive" do
    price > 0
  end

  # Lifecycle (state machine)
  attribute :status, String, default: "draft" do
    transition "PublishPizza" => "published", from: "draft"
    transition "ArchivePizza" => "archived", from: ["draft", "published"]
  end

  # Queries
  query "ByDescription" do |desc|
    where(description: desc)
  end

  # Scopes
  scope :active, status: "active"
  scope :by_style, ->(style) { { style: style } }

  # Indexes
  index :email, unique: true
  index :name, :status

  # Specifications (reusable predicates)
  specification "HighValue" do |pizza|
    pizza.price > 20
  end

  # Policies (reactive: event -> trigger)
  policy "NotifyKitchen" do
    on "CreatedPizza"
    trigger "PrepareIngredients"
    async true
    condition { |event| event.name != "Test" }
  end

  # Ports (access control per role)
  port :admin do
    allow :find, :all, :create_pizza, :archive_pizza
  end
  port :guest, [:find, :all]

  # Event subscribers
  on_event "CreatedPizza", async: true do |event|
    puts "Pizza created: #{event.name}"
  end

  # Repository interface
  repository :find, :all, :save, :delete

  # Factories
  factory "BuildFromCart" do
    attribute :cart_id, String
  end

  # Explicit events (not inferred from commands)
  event "PizzaExpired" do
    attribute :reason, String
  end

  # Computed attributes (derived, not stored)
  computed :lot_size do
    area / 43560.0
  end

  # Versioning and attachments
  versioned
  attachable
end
```

### Implicit syntax

Inside an aggregate block, you can use shorthand — bare names with types become attributes, PascalCase with blocks become value objects, and snake_case with blocks become commands:

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

---

## Command

A command is an intent to change state — "create this pizza", "place this order", "cancel this subscription". Commands are the only way to modify aggregates. Each command automatically infers a domain event by converting the verb to past tense (CreatePizza -> CreatedPizza).

A command that includes a self-referencing `reference_to` (pointing to its own aggregate) is an **update** command — the runtime finds the existing aggregate by ID and applies the changes. A command without a self-reference is a **create** command — the runtime constructs a new aggregate.

```ruby
command "PlaceOrder" do
  # Input attributes
  attribute :customer_name, String
  attribute :quantity, Integer

  # References to other aggregates
  reference_to "Pizza"
  reference_to "Restaurant", role: "pickup_location"

  # Guard policy (must pass before execution)
  guarded_by "MustBeAuthenticated"

  # Static field assignments
  sets status: "pending", ordered_at: :now

  # Actors who can issue this command
  actor "Customer"
  actor "Admin"

  # Documentation: what data this command needs
  read_model "Menu & Availability"

  # External system dependencies
  external "PaymentGateway"

  # Pre/postconditions
  precondition "quantity must be positive" do |agg|
    quantity > 0
  end

  postcondition "order count increased" do |before, after|
    after.count > before.count
  end

  # Custom handler (overrides default create/update)
  handler do |cmd, agg|
    # complex domain logic
  end

  # Or inline call body
  call do
    # lightweight logic
  end
end
```

### Event inference

The command verb is automatically converted to past tense:

| Command | Inferred Event |
|---------|---------------|
| CreatePizza | CreatedPizza |
| PlaceOrder | PlacedOrder |
| SubmitApplication | SubmittedApplication |
| SendInvoice | SentInvoice |
| DenyRequest | DeniedRequest |

### emits — explicit event names

Generated command classes use `emits` to declare the event name rather than relying on the inferred past-tense conjugation. This is useful when the inferred name is awkward or when a command should emit a domain-specific event name:

```ruby
class PublishPost
  include Hecks::Command
  emits "PostPublished"   # overrides inferred "PublishedPost"

  def call
    Post.new(...)
  end
end
```

The `emits` declaration is set automatically by the code generator based on the domain IR. When using the DSL, the inferred event name is used unless the command has an explicit `emits:` value in the IR.

### Implicit syntax

Inside a command block:

```ruby
command "CreatePizza" do
  name String        # attribute :name, String
  price Float        # attribute :price, Float
end
```

---

## Reference

In DDD, aggregates don't contain each other — they reference each other. A reference says "this Order knows about a Pizza" without the Order owning the Pizza. The domain layer works with live objects, never with foreign key IDs. The persistence layer handles the ID conversion transparently.

Use `reference_to` when one aggregate needs to know about another. If you need multiple references to the same type (e.g., home_team and away_team both pointing to Team), use the `role:` option.

```ruby
aggregate "Order" do
  # Role defaults to downcased type name (:pizza)
  reference_to "Pizza"

  # Explicit role (required when multiple refs to same type)
  reference_to "Team", role: "home_team"
  reference_to "Team", role: "away_team"

  # Cross-domain reference
  reference_to "Billing::Invoice"

  # References in commands
  command "PlaceOrder" do
    reference_to "Pizza"
    attribute :quantity, Integer
  end
end
```

Reference kinds (inferred automatically after build):

| Kind | When |
|------|------|
| `:composition` | Target is a value object or entity within the same aggregate |
| `:aggregation` | Target is another aggregate root |
| `:cross_context` | Target is in a different bounded context (qualified with `::`) |

---

## Types

Hecks supports Ruby's built-in types plus collection and custom type references. Attributes are the data fields on aggregates, value objects, entities, commands, and events.

### Built-in types

| Type | Aliases |
|------|---------|
| `String` | `:string`, `:str` |
| `Integer` | `:integer`, `:int` |
| `Float` | `:float` |
| `TrueClass` (Boolean) | `:boolean`, `:bool` |
| `Symbol` | `:symbol`, `:sym` |
| `Array` | `:array` |
| `Hash` | `:hash` |
| `Date` | `:date` |
| `DateTime` | `:datetime` |
| `JSON` | (use directly) |

### Collection types

```ruby
attribute :toppings, list_of("Topping")
attribute :tags, list_of(String)
```

### Custom types

PascalCase strings reference value objects, entities, or other domain types:

```ruby
attribute :address, "Address"     # references a value object
attribute :status, "OrderStatus"  # references a custom type
```

### Attribute options

```ruby
attribute :name, String                          # required, no default
attribute :status, String, default: "draft"      # with default
attribute :role, String, enum: ["admin", "user"] # constrained values
attribute :email, String, pii: true              # PII flag
```

### Identity (natural key)

Aggregates always have a UUID as their canonical ID. You can additionally declare a natural key composed from attributes for human-meaningful lookups and deduplication. PII attributes cannot be part of the identity.

```ruby
aggregate "TeamCycle" do
  attribute :team, String
  attribute :start_date, Date

  identity :team, :start_date
end

# TeamCycle.find(uuid)                                    # always works
# TeamCycle.find_by_identity(team: "Alpha", start_date: Date.today)  # natural key
```

---

## Computed Attributes

Computed attributes are derived values calculated from other attributes. They generate methods on the aggregate class but are not stored in the database. The block body becomes the method body.

```ruby
aggregate "Parcel" do
  attribute :area, Float
  attribute :density, Float

  computed :lot_size do
    area / 43560.0
  end

  computed :total_units do
    (area * density).ceil
  end
end
```

At runtime:

```ruby
parcel = Parcel.create(area: 87120.0, density: 0.5)
parcel.lot_size    # => 2.0
parcel.total_units # => 43561
```

Computed attribute names must not collide with regular attribute names (the validator will catch this). They appear in the web explorer with a "(computed)" label but are not shown on command forms.

---

## Lifecycle

A lifecycle is a state machine on a single attribute. It declares which commands trigger which state transitions, and optionally constrains which source states are valid. The runtime enforces these transitions — if you try to publish a post that's already archived, it raises an error.

Declare as a block on the attribute itself (the `default:` becomes the initial state):

```ruby
attribute :status, String, default: "draft" do
  transition "SubmitForReview" => "pending"
  transition "ApprovePost" => "published", from: "pending"
  transition "RejectPost" => "rejected", from: "pending"
  transition "ArchivePost" => "archived", from: ["published", "rejected"]
end
```

Or as a separate declaration:

```ruby
lifecycle :status, default: "draft" do
  transition "SubmitForReview" => "pending"
  transition "ApprovePost" => "published", from: "pending"
end
```

The `from:` constraint is optional. Without it, the transition is allowed from any state. With it, the runtime raises an error if the current state doesn't match.

State predicates are generated automatically:

```ruby
post.draft?      # => true
post.published?  # => false
```

---

## Policy

Policies are the domain's reaction system. A reactive policy listens for a domain event and automatically triggers another command — "when an order is placed, create an invoice." This is how you coordinate between aggregates without coupling them directly.

Guard policies are pre-checks that run before a command executes — "only admins can delete posts."

### Reactive policy

```ruby
# On an aggregate
policy "NotifyChef" do
  on "PlacedOrder"
  trigger "PrepareIngredients"
  async true
  map pizza: :pizza, quantity: :servings
  defaults priority: "normal"
  condition { |event| event.quantity > 5 }
end

# Cross-aggregate (domain level)
policy "CreateInvoice" do
  on "PlacedOrder"
  trigger "GenerateInvoice"
  map order: :reference
end
```

### Guard policy

```ruby
policy "MustBeAdmin" do |cmd|
  cmd.role == "admin"
end
```

Referenced from commands with `guarded_by "MustBeAdmin"`.

---

## Validation and Invariants

Validations are field-level checks (is this field present? is it the right type? is it unique?). Invariants are aggregate-level business rules that must always hold true — they're checked after every state change.

The difference: validations check individual fields in isolation, invariants check relationships between fields or complex business logic.

### Validations (field-level)

```ruby
validation :name, presence: true
validation :email, presence: true, type: String, uniqueness: true
```

### Invariants (aggregate-level business rules)

```ruby
invariant "price must be positive" do
  price > 0
end

invariant "end date after start date" do
  end_date > start_date
end
```

Value objects and entities also support invariants:

```ruby
value_object "Money" do
  attribute :amount, Float
  attribute :currency, String
  invariant "amount must be non-negative" do
    amount >= 0
  end
end
```

---

## Access Control (Gates)

Access control is an infrastructure concern, not a domain concept. Gates (formerly "ports") are declared in the [Hecksagon](hecksagon_reference.md), not the Bluebook. See the Hecksagon DSL Reference for gate syntax.

The `port` keyword in the Bluebook is a no-op kept for backward compatibility. For the full rationale on the ports-vs-gates split and how to migrate, see [Architecture Decisions: Ports vs Gates](architecture_decisions.md#2-ports-vs-gates-naming-and-responsibility-split).

---

## Query and Scope

Queries and scopes give you named, reusable ways to find aggregates. Queries are custom logic blocks that can accept parameters. Scopes are simpler — either static condition hashes or parameterized lambdas.

Both are wired as class methods on the aggregate at runtime: `Pizza.by_description("Classic")` or `Pizza.classics_scope`.

### Queries (custom logic)

```ruby
query "ByDescription" do |desc|
  where(description: desc)
end

query "Classics" do
  where(style: "Classic").order(:name)
end
```

### Scopes (named filters)

```ruby
# Hash scope (static conditions)
scope :active, status: "active"
scope :premium, tier: "premium"

# Lambda scope (parameterized)
scope :by_price, ->(min) { { price: Hecks::Querying::Operators::Gte.new(min) } }
```

### Indexes

Indexes declare which fields should be indexed in the database for query performance:

```ruby
index :email, unique: true
index :name, :status           # composite index
```

---

## Specification

A specification is a named boolean predicate — "is this loan high risk?", "is this invoice overdue?" Specifications are reusable: you can use them to filter collections, branch in workflows, or validate conditions.

They're the DDD way to extract complex conditional logic into a named, testable object.

```ruby
specification "HighRisk" do |loan|
  loan.principal > 50_000
end

specification "Overdue" do |invoice|
  invoice.due_date < Date.today && invoice.status == "unpaid"
end
```

Used in workflows:

```ruby
workflow "LoanApproval" do
  branch do
    when_spec("HighRisk") { step "ManualReview" }
    otherwise { step "AutoApprove" }
  end
end
```

---

## Booting

Hecks compiles your domain definition into a running application. `boot` loads the domain from a directory, validates it, generates Ruby classes, and wires everything together. `load` does the same from an in-memory domain object.

### Standalone app

```ruby
# Boot from a directory containing hecks_domain.rb
app = Hecks.boot(__dir__)

# With SQL persistence
app = Hecks.boot(__dir__, adapter: :sqlite)
```

### Rails

```ruby
# config/initializers/hecks.rb
Hecks.configure do |config|
  config.domain_path = Rails.root.join("app/domain")
  config.adapter = :memory
end
```

### Running commands

Commands become class methods on the aggregate. References accept either a live object or a raw ID string at the boundary:

```ruby
pizza = Pizza.create(name: "Margherita", description: "Classic")
order = Order.place(pizza: pizza, customer_name: "Alice", quantity: 3)

# Or with a raw ID at the boundary:
Order.place(pizza: "some-uuid", quantity: 3)

Pizza.find(pizza.id)
Pizza.all
Pizza.count
Pizza.by_description("Classic")
```

### Events

```ruby
app.on("CreatedPizza") do |event|
  puts "#{event.name} created at #{event.occurred_at}"
end

app.events  # => array of all published events
```
