---
name: hecks-testing
description: 'Testing patterns for the Hecks framework. Use when writing specs, setting up test domains, or debugging test failures. Covers memory adapters, inline domains, constant cleanup, speed requirements, and spec organization.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Hecks Testing Patterns

## Speed Rule

All specs must run under 1 second total. Enforced by pre-commit hook. Adjust with `SPEC_SPEED_LIMIT=2` if needed.

## Spec Organization

Specs mirror lib paths:
- `hecksties/lib/hecks/runtime.rb` → `hecksties/spec/runtime/` 
- `bluebook/lib/hecks/dsl/` → `bluebook/spec/dsl/`

Run specs:
```bash
bundle exec rspec                           # full suite
bundle exec rspec hecksties/spec/runtime/   # one directory
bundle exec rspec path/to/spec.rb:42        # one example
```

## Inline Domain Pattern

Define domains inline in specs — never load from files:

```ruby
let(:domain) do
  Hecks.domain "Pizzas" do
    aggregate "Pizza" do
      attribute :name, String
      attribute :style, String

      command "CreatePizza" do
        attribute :name, String
        attribute :style, String
      end

      query "ByStyle" do
        where(style: :style)
      end
    end
  end
end

subject(:app) { Hecks.load(domain) }
```

## Memory Adapters

Tests always use memory adapters (the default). Never require a database. `Hecks.load(domain)` wires memory repos automatically.

## Constant Cleanup

Hecks defines constants on `Object` (e.g., `PizzasDomain`, `Pizza`). Clean them up:

```ruby
after { Hecks::Utils.cleanup_constants! }
```

Or use the shared boot helper:
```ruby
require_relative "support/shared_boot"
```

## Common Test Patterns

### Testing commands
```ruby
it "creates a pizza" do
  result = app.run("CreatePizza", name: "Margherita", style: "Classic")
  expect(result.name).to eq("Margherita")
  expect(app.events.size).to eq(1)
end
```

### Testing via class methods
```ruby
it "creates via class method" do
  pizza = Pizza.create(name: "Margherita", style: "Classic")
  expect(pizza.name).to eq("Margherita")
  expect(Pizza.count).to eq(1)
end
```

### Testing events
```ruby
it "publishes events" do
  app.run("CreatePizza", name: "Margherita", style: "Classic")
  event = app.events.last
  expect(event).to be_a(PizzasDomain::Pizza::Events::CreatedPizza)
  expect(event.name).to eq("Margherita")
end
```

### Testing policies
```ruby
it "triggers reactive policy" do
  Pizza.create(name: "Margherita", style: "Classic")
  pizza = Pizza.all.first
  Order.place(pizza: pizza.id, quantity: 3)
  # Policy should have triggered NotifyChef
  expect(app.events.map { |e| Hecks::Utils.const_short_name(e) })
    .to include("NotifiedChef")
end
```

### Testing dry-run
```ruby
it "previews without side effects" do
  result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")
  expect(result.valid?).to be true
  expect(result.aggregate.name).to eq("Margherita")
  expect(Pizza.count).to eq(0)  # nothing persisted
end
```

### Testing guards
```ruby
it "rejects unauthorized commands" do
  expect { app.run("DeletePizza", pizza_id: "123") }
    .to raise_error(Hecks::GuardRejected)
end
```

### Testing lifecycle
```ruby
it "transitions status" do
  loan = Loan.create(amount: 1000)
  expect(loan.status).to eq("pending")
  Loan.approve(loan_id: loan.id)
  approved = Loan.find(loan.id)
  expect(approved.status).to eq("approved")
end
```

## Anti-Patterns

- **Don't use `before(:all)`** — constants leak between examples
- **Don't load external domain files** — define inline
- **Don't test persistence** — memory adapter is the contract
- **Don't sleep** — everything is synchronous in tests
- **Don't mock the repository** — use the real memory adapter
- **Don't use `Hecks.boot`** in specs — use `Hecks.load(domain)` for isolation
