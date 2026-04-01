# Hecks for DDD Practitioners

If you've read Evans, this is how Hecks maps to the blue book patterns.

## Aggregate Roots

`aggregate` in the DSL. Generated as a class with identity equality (`==` compares by UUID), auto-generated identity, and construction-time validation. The aggregate boundary is enforced — cross-aggregate references are by ID only, validated at build time.

```ruby
aggregate "Pizza" do          # Chapter 6: Aggregates
  attribute :name, String
  attribute :toppings, list_of("Topping")
  validation :name, presence: true
  invariant "name can't be blank" do
    !name.empty?
  end
end
```

## Value Objects

`value_object` in the DSL, nested inside an aggregate. Generated as frozen, immutable objects with equality by attributes (not identity). Support invariants for business rules.

```ruby
value_object "Topping" do     # Chapter 5: Value Objects
  attribute :name, String
  attribute :amount, Integer
  invariant "amount must be positive" do
    amount > 0
  end
end
```

## Commands

`command` in the DSL. Represents intent — a request to change state. Each command automatically infers a corresponding domain event (`CreatePizza` → `CreatedPizza`). Commands dispatch through a CommandBus with middleware support (Chapter 10: Supple Design).

Commands support event-storming annotations: `read_model` names a read model dependency, `external` names an external system, and `actor` names who triggers the command. These appear in documentation and MCP introspection but don't affect runtime behavior.

```ruby
command "CreatePizza" do      # Application Service pattern
  attribute :name, String
  attribute :description, String
  guarded_by "MustBeAdmin"    # optional: references a guard policy
  read_model "Menu"           # optional: event storm annotation
  external "Stripe"           # optional: external system dependency
  actor "Customer"            # optional: who triggers this command
end
```

## Domain Events

Auto-generated from commands. Frozen, immutable facts with `occurred_at` timestamps. Published through an in-process EventBus. With `event_sourced: true`, events persist to a `domain_events` table for full audit history.

```ruby
# CreatedPizza event auto-generated from CreatePizza command
app.on("CreatedPizza") { |event| puts event.name }
```

## Policies

`policy` in the DSL. Hecks supports two kinds:

**Reactive policies** subscribe to domain events and trigger commands — Evans' "domain event subscribers" pattern. They're the mechanism for cross-aggregate communication.

```ruby
policy "ReserveIngredients" do   # Chapter 14: Model Integrity
  on "PlacedOrder"
  trigger "ReserveStock"
end
```

**Guard policies** validate commands before execution. The command references a guard policy by name with `guarded_by`. The guard block receives the command and must return truthy to allow it.

```ruby
policy "MustBeAdmin" do |command|   # Authorization guard
  command.role == "admin"
end

command "DeletePizza" do
  attribute :pizza_id, reference_to("Pizza")
  guarded_by "MustBeAdmin"
end
```

## Validations

`validation` in the DSL. Declarative attribute constraints checked at construction time. Supports `:presence` (non-nil/non-empty) and `:type` checks. Raises `ValidationError` on failure.

```ruby
aggregate "Order" do
  attribute :quantity, Integer
  validation :quantity, presence: true
end
```

## Invariants

`invariant` in the DSL. Business rule constraints checked at construction time on both aggregates and value objects. The block is evaluated in the object's context. Raises `InvariantError` on failure.

```ruby
invariant "amount must be positive" do
  amount > 0
end
```

## Scopes

`scope` in the DSL. Named, reusable query filters bound as class methods on aggregates at boot time. Support hash-based (static) and parameterized (lambda) forms. Returns a chainable `QueryBuilder`.

```ruby
aggregate "Order" do
  scope :pending, status: "pending"       # hash-based

  scope :by_size do |size|                # parameterized
    { size: size }
  end
end

# Usage:
Order.pending.count
Order.by_size("L").to_a
```

## Query Objects

`query` in the DSL. Named, reusable queries defined as domain concepts. They use a `QueryBuilder` that delegates to the adapter — memory adapters filter in Ruby, SQL adapters build Sequel datasets.

```ruby
query "ByDescription" do |desc|    # Repository pattern: named queries
  where(description: desc)
end

# Usage:
Pizza.by_description("Classic").to_a
```

## Ports

`port` in the DSL. Access control boundaries that restrict which repository methods are available through a named port. Raises `PortAccessDenied` on disallowed method calls.

```ruby
aggregate "Pizza" do
  port :guest do
    allow :find, :all, :where
  end
end
```

## Repositories

Not in the DSL — they're infrastructure. Hecks generates memory repositories by default and SQL repositories on demand. The `RepositoryMethods` mixin binds `find`, `save`, `create`, `delete` onto aggregate classes at boot time. The domain never references repositories directly.

The `.bind` pattern implements Ports and Adapters (Hexagonal) architecture:

```ruby
# Domain layer: pure aggregate class (no persistence knowledge)
# Infrastructure layer: RepositoryMethods.bind(Pizza, repo) at boot
# Application layer: AggregateWiring orchestrates binding
```

## Ports and Adapters

The hexagonal architecture is implemented via the module grouping pattern:

- **Persistence** — `RepositoryMethods`, `CollectionMethods`, `ReferenceMethods`
- **Querying** — `QueryBuilder`, `AdHocQueries`, `ScopeMethods`, `Operators`
- **Commands** — `CommandBus`, `CommandMethods`

Each group has a `.bind` method that injects behavior into aggregate classes at boot time. The domain gem has zero knowledge of these — they're wired by `AggregateWiring` in the application layer.

## Event Sourcing

Opt in with `adapter :sql, event_sourced: true` in `Hecks.configure`. Every command records its event to a `domain_events` table (stream ID, event type, JSON data, version) alongside the regular SQL state. The `EventRecorder` provides `history(aggregate_type, id)` for full event streams. Regular SQL tables serve as the read model, so queries stay fast.

## What Hecks Validates (DDD Rules)

12 rules enforced at build time:

| Rule | Evans Pattern |
|------|--------------|
| Aggregates must have commands | Aggregates need behavior |
| Commands must be verbs | Ubiquitous Language |
| Commands must have attributes | Intent requires data |
| No self-references | Aggregate boundary |
| No bidirectional references | Aggregate boundary |
| References must target existing aggregates | Aggregate Root references |
| Value objects can't hold references | Value Object purity |
| No name collisions | Ubiquitous Language clarity |
| Unique aggregate names | Ubiquitous Language |
| Reserved names rejected | Ruby keyword safety |
| Policy events must exist | Model integrity |
| Policy triggers must exist | Model integrity |
