---
name: hecks-bluebook-dsl
description: 'Complete Bluebook DSL reference for the Hecks domain compiler. Use when writing or modifying domain definitions, understanding DSL syntax, or modeling domains. Covers all keywords: aggregates, attributes, commands, events, policies, lifecycles, references, value objects, entities, queries, scopes, specifications, services, views, workflows, ports, and the implicit DSL.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Bluebook DSL Reference

The Bluebook DSL is the source of truth for all Hecks domain models. It compiles into an in-memory IR (Hecksagon) that feeds code generators for Ruby, Go, and other targets.

## Domain Block

```ruby
Hecks.domain "Pizzas" do
  # everything lives inside here
end
```

## Aggregates

The primary building block. An aggregate is a cluster of domain objects with a root entity.

```ruby
aggregate "Pizza" do
  String :name
  String :style, enum: %w[classic tropical spicy]
  Float :price

  # Commands, value objects, entities, etc. go here
end
```

### Attributes

```ruby
# Primary (shorthand)
String :name                                     # typed attribute
Integer :count
Float :price
Boolean :active
JSON :metadata
Date :born_on
DateTime :created_at
list_of(String) :tags                            # collection
String :category, enum: %w[a b c]               # enum constraint
Integer :score, default: 0                       # default value

# Also supported (verbose)
attribute :name, String
attribute :count, Integer
attribute :tags, list_of("String")
attribute :name                                  # default type is String
```

**Symbol shorthand:** `:string`, `:integer`, `:float`, `:boolean`, `:date`, `:datetime`

### References

```ruby
# Primary
reference_to(Order)                              # cross-aggregate reference
reference_to(Order).as(:recent_purchase)         # named role
reference_to(Billing::Invoice)                   # cross-domain reference

# Also supported (verbose)
reference_to "Order"
reference_to "Team", role: "home_team"
```

References hold live objects in memory. IDs are a persistence concern only.

## Value Objects

Immutable nested types defined inside an aggregate. No identity.

```ruby
aggregate "Pizza" do
  value_object "Topping" do
    String :name
    Integer :quantity

    invariant "quantity must be positive" do |vo|
      vo.quantity > 0
    end
  end

  list_of(Topping) :toppings
end
```

## Entities

Sub-objects with identity (UUID). Mutable, not frozen.

```ruby
aggregate "Order" do
  entity "LineItem" do
    String :product
    Integer :quantity
  end
end
```

## Commands

Commands are verb-phrase named actions that modify aggregate state.

```ruby
# Primary (bare PascalCase)
CreatePizza do
  description "Add a new pizza to the menu"
  String :name
  String :style
  emits "PizzaCreated"
end

BakePizza do
  Integer :temperature

  # Guard policy (authorization)
  guard do
    actor :chef
    description "Only chefs can bake"
  end

  # Static field assignment
  sets status: "baking"

  # Inline business logic (prototyping)
  call do
    # Ruby code executed at runtime
  end
end

# Also supported (verbose)
command "CreatePizza" do
  attribute :name, String
  attribute :style, String
end
```

### Auto-inferred Events

Every command auto-generates a past-tense event: `CreatePizza` → `CreatedPizza`, `BakePizza` → `BakedPizza`. Events carry command attrs + all aggregate attrs.

### Transition Commands

Commands that participate in a lifecycle must have a self-referencing ID attribute so the generator treats them as updates, not creates:

```ruby
ApproveLoan do
  reference_to(Loan) :loan_id                   # self-ref ID
  sets status: "approved"
end
```

## Lifecycle (State Machines)

```ruby
lifecycle :status, default: "draft" do
  transition "SubmitPizza" => "submitted"
  transition "ApprovePizza" => "approved"
  transition "RejectPizza" => "rejected"
end
```

- Generates predicates: `model.draft?`, `model.submitted?`
- Commands auto-set status to declared target
- Transition commands enforce `from` constraints

## Policies

### Guard Policies (Authorization)

Defined inside a command block:

```ruby
guard do
  actor :admin
  description "Only admins can delete"
end
```

### Reactive Policies (Event-Driven)

Defined inside an aggregate or at domain level:

```ruby
policy "NotifyOnOrder" do
  on "PlacedOrder"
  trigger "SendNotification"
  async true                                     # optional async
  condition { |event| event.quantity > 10 }       # optional filter
  map recipient: :customer_name                   # attribute mapping
  defaults channel: "email"                       # static injection
end
```

## Queries

```ruby
query "ClassicPizzas" do
  where style: "Classic"
  order :name
  limit 10
end
```

## Scopes

```ruby
scope :active, status: "active"                  # hash condition
scope :expensive, ->(pizza) { pizza.price > 20 }  # lambda predicate
```

## Specifications

Reusable composable predicates:

```ruby
specification "HighValue" do
  satisfied_by { |order| order.total > 1000 }
end
```

Composable: `spec.and(other)`, `spec.or(other)`, `spec.not`

## Validations

```ruby
validation :name, presence: true
validation :email, uniqueness: true
validation :name, length: { min: 2, max: 50 }
validation :email, format: /@/
```

## Indexes

```ruby
index :email, unique: true
index :name
```

## Invariants

Aggregate-level constraints:

```ruby
invariant "price must be positive" do |agg|
  agg.price > 0
end
```

## Domain Services

Orchestrate multiple commands across aggregates:

```ruby
service "TransferMoney" do
  String :source_id
  String :dest_id
  Float :amount
  coordinates "Account", "Ledger"
  call do
    dispatch("Withdraw", account_id: source_id, amount: amount)
    dispatch("Deposit", account_id: dest_id, amount: amount)
  end
end
```

Wired as: `Banking.transfer_money(source_id: ..., dest_id: ..., amount: ...)`

## Views (Read Model Projections)

```ruby
view "OrderSummary" do
  project("PlacedOrder") { |event, state| state.merge(total: event.quantity) }
end
```

## Workflows

```ruby
workflow "LoanApproval" do
  step "ScoreLoan", score: :principal
  branch do
    when_spec("HighRisk") { step "ReviewLoan" }
    otherwise { step "ApproveLoan" }
  end
end
```

## Ports (Access Control)

```ruby
port :admin, [:create_pizza, :delete_pizza]
port :customer, [:place_order]
```

## Event Subscribers

```ruby
on_event "CreatedPizza" do |event|
  puts "Pizza created: #{event.name}"
end
```

## Actors

```ruby
actor "Customer"
actor "Admin", description: "System administrator"
```

## Multi-Domain

```ruby
# In Hecksagon file:
subscribe "Pizzas"  # subscribe to another domain's events
```

## Implicit DSL (Sugar)

```ruby
Hecks.domain "Blog" do
  Post do                              # PascalCase block → aggregate
    String :title                      # Type :name → attribute
    String :body
    Boolean :published

    create do                          # snake_case block → command (CreatePost)
      String :title
    end

    Address do                         # nested PascalCase → value object
      String :street
      String :city
    end

    reference_to(Author)               # paren syntax for references
  end
end
```

Both explicit and implicit forms can be mixed in the same file.
