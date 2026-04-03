# Metric Attribute Tag

The `metric` tag marks aggregate attributes for automatic change tracking.
Whenever a tagged attribute changes value during a command, an entry is appended
to `Hecks.metric_log`. A pluggable sink forwards entries to StatsD, Prometheus,
or any other observability backend.

## Tagging attributes in the Hecksagon

```ruby
# In *Hecksagon or Hecks.hecksagon block
Hecks.hecksagon do
  aggregate "Pizza" do
    capability.order_count.metric
    capability.revenue.metric
  end
end
```

The Bluebook stays pure domain — metric tagging is an infrastructure concern
declared in the Hecksagon.

## What gets captured

Each log entry is a plain Ruby Hash:

```ruby
{
  aggregate: "Pizza",
  attribute: :order_count,
  old:       0,
  new:       3,
  command:   "AddOrder",
  timestamp: 2026-04-02 12:00:00 UTC
}
```

Entries are only written when the value **changes** — unchanged attributes
produce no entry.

## Reading the log

```ruby
Hecks.metric_log
# => [{ aggregate: "Pizza", attribute: :order_count, old: 0, new: 3, ... }]

Hecks.metric_log.last[:new]   # => 3
Hecks.metric_log.clear        # flush
```

## Custom sink (StatsD, Prometheus, etc.)

```ruby
# Register once at boot
Hecks.metric_sink = ->(entry) do
  StatsD.gauge("hecks.#{entry[:aggregate]}.#{entry[:attribute]}", entry[:new])
end
```

When a sink is set, entries are **both** appended to `metric_log` and forwarded
to the sink — so you can keep the in-memory log for debugging while also
pushing to an external system.

## Full boot example

```ruby
# PizzasBluebook
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :order_count, Integer
    attribute :name, String

    command "CreatePizza" do
      attribute :name, String
    end

    command "AddOrder" do
      reference_to "Pizza", validate: :exists
      attribute :order_count, Integer
    end
  end
end

# PizzasHecksagon
Hecks.hecksagon do
  aggregate "Pizza" do
    capability.order_count.metric
  end
end

# app.rb
app = Hecks.boot(__dir__)

Hecks.metric_sink = ->(e) { puts "#{e[:attribute]}: #{e[:old]} → #{e[:new]}" }

pizza = Pizza.create(name: "Margherita")
Pizza.add_order(pizza: pizza.id, order_count: 5)
# Output: order_count: nil → 5

Pizza.add_order(pizza: pizza.id, order_count: 5)
# No output — value unchanged
```

## How it works

The metrics extension is auto-loaded (it is in the `AUTO` list in
`LoadExtensions`). At boot, it:

1. Reads `aggregate_capabilities` from the Hecksagon IR for each aggregate
2. Filters for tags where `tag == :metric`
3. Installs a command bus middleware (`runtime.use :metrics`) that:
   - Looks up the entity **before** the command runs via the repository
   - Runs the command
   - Compares before/after values for each tagged attribute
   - Emits entries for changed values only

Create commands (no self-referencing ID) will have `old: nil` since there is
no prior state.
