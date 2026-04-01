# Command Dry-Run Mode

Preview what a command would do — without persisting state or firing events.

## Usage

```ruby
require "hecks"
app = Hecks.boot(__dir__)

result = app.dry_run("CreatePizza", name: "Margherita", style: "Classic")

result.valid?          # => true
result.aggregate.name  # => "Margherita"
result.event           # => #<PizzasDomain::Pizza::Events::CreatedPizza ...>
result.event.name      # => "Margherita"
```

## What it checks

Dry-run executes the full validation pipeline:

1. **Guards** — authorization policies (raises `GuardRejected`)
2. **Handler** — optional handler callback
3. **Preconditions** — business rule checks (raises `PreconditionError`)
4. **Call** — domain logic that builds the aggregate
5. **Postconditions** — before/after state assertions (raises `PostconditionError`)

## What it skips

- Persist — no `repository.save`
- Emit — no `event_bus.publish`
- Record — no event recorder entry

## Reactive chain preview

Dry-run traces which policies would fire and what downstream commands they'd trigger:

```ruby
result = app.dry_run("PlaceOrder", pizza: pizza_id, quantity: 3)

result.triggers_policies?  # => true
result.reactive_chain
# => [{type: :policy, policy: "NotifyKitchen", event: "PlacedOrder",
#      command: "NotifyChef", aggregate: "Order"}]
```

## Error handling

Validation errors raise normally — rescue them to inspect failures:

```ruby
begin
  app.dry_run("ApproveLoan", loan_id: "123")
rescue Hecks::GuardRejected => e
  puts "Not authorized: #{e.message}"
rescue Hecks::PreconditionError => e
  puts "Precondition failed: #{e.message}"
end
```

## Use cases

- Validate a form before submit
- Preview approval workflows
- What-if analysis ("what would happen if I run this?")
- CI/CD pipeline checks
