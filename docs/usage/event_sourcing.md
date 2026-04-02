# Event Sourcing

Phase 3 event sourcing infrastructure: optimistic concurrency, CQRS read
model stores, event upcasting, projection rebuilding, outbox pattern,
process managers, aggregate snapshots, and time travel.

## Optimistic Concurrency (HEC-65)

```ruby
require "hecks"

aggregate = Pizza.create(name: "Margherita")
Hecks::EventSourcing::Concurrency.stamp!(aggregate, 1)

# Later, check before saving:
Hecks::EventSourcing::Concurrency.check!(expected: 1, actual: 1)  # OK
Hecks::EventSourcing::Concurrency.check!(expected: 1, actual: 2)  # raises ConcurrencyError
```

## CQRS Read Model Store (HEC-63)

```ruby
store = Hecks::EventSourcing::ReadModelStore.new
store.put("orders:summary", { total: 5, revenue: 250 })
store.get("orders:summary")   # => { total: 5, revenue: 250 }
store.keys                     # => ["orders:summary"]
store.delete("orders:summary")
```

## Event Versioning & Upcasting (HEC-70)

```ruby
registry = Hecks::EventSourcing::UpcasterRegistry.new
registry.register("CreatedPizza", from: 1, to: 2) do |data|
  data.merge("size" => "medium")
end

engine = Hecks::EventSourcing::UpcasterEngine.new(registry)
engine.upcast("CreatedPizza", { "name" => "M" }, from_version: 1)
# => { "name" => "M", "size" => "medium" }
```

## Event Store & Projection Rebuilding (HEC-64)

```ruby
store = Hecks::EventSourcing::EventStore.new
store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" })
store.append("Pizza-1", event_type: "RenamedPizza", data: { "name" => "N" })

projections = {
  "CreatedPizza" => ->(data, state) { state.merge(name: data["name"]) },
  "RenamedPizza" => ->(data, state) { state.merge(name: data["name"]) }
}

rebuilder = Hecks::EventSourcing::ProjectionRebuilder.new(store)
state = rebuilder.rebuild(projections)
# => { name: "N" }
```

## Outbox Pattern (HEC-80)

```ruby
outbox = Hecks::EventSourcing::Outbox.new
bus = Hecks::EventBus.new
poller = Hecks::EventSourcing::OutboxPoller.new(outbox, bus)

# Store event in outbox (atomically with command)
outbox.store(my_event)

# Later, publish pending events
poller.poll_once  # => 1 (number published)
```

## Process Managers (HEC-67)

```ruby
pm = Hecks::EventSourcing::ProcessManager.new(
  name: "OrderFulfillment",
  store: Hecks::SagaStore.new
)

pm.on("OrderPlaced", correlate: :order_id, transition: { nil => :started }) do |event, instance|
  { commands: ["ReserveInventory"] }
end
pm.on("InventoryReserved", correlate: :order_id, transition: { started: :reserved })
pm.on("PaymentReceived", correlate: :order_id, transition: { reserved: :completed })

pm.subscribe_to(event_bus)
```

## Aggregate Snapshots & Reconstitution (HEC-69)

```ruby
event_store = Hecks::EventSourcing::EventStore.new
snap_store = Hecks::EventSourcing::SnapshotStore.new

appliers = {
  "Created" => ->(state, data) { state.merge(name: data["name"]) },
  "Renamed" => ->(state, data) { state.merge(name: data["name"]) }
}

# Auto-snapshot every 10 events
recon = Hecks::EventSourcing::Reconstitution.new(
  event_store, snapshot_store: snap_store, snapshot_interval: 10
)
state = recon.reconstitute("Pizza-1", appliers)
```

## Time Travel (HEC-98)

```ruby
tt = Hecks::EventSourcing::TimeTravel.new(event_store)

# State at a specific point in time
state = tt.as_of("Pizza-1", Time.new(2026, 1, 1, 12, 0, 0), appliers)

# State at a specific version
state = tt.at_version("Pizza-1", 3, appliers)
```
