# Outbox Pattern -- Reliable Event Publishing

The outbox extension guarantees at-least-once delivery of domain events. Instead of publishing events directly to the event bus (where listeners might fail), events are stored in a local outbox first. A synchronous poller then drains the outbox and publishes to the bus.

## Quick Start

```ruby
app = Hecks.load(domain)
app.extend(:outbox, enabled: true)

Pizza.create(name: "Margherita")

# Events were stored in the outbox, then drained to the bus
Hecks.outbox.entries.size      # => 1
Hecks.outbox.pending_count     # => 0  (already drained)
app.events.size                # => 1  (delivered via poller)

# Poller stats
Hecks.outbox_poller.stats      # => { published: 1, pending: 0 }
```

## How It Works

1. The extension wraps `event_bus.publish` to redirect events into the outbox
2. After each command dispatch, middleware drains the outbox
3. The poller reads unpublished entries and delivers them via the original publish path
4. Each entry is marked as published so it won't be delivered again

## Outbox Port API

```ruby
outbox = Hecks::Outbox::MemoryOutbox.new

# Store an event
entry = outbox.store(event)
entry[:id]         # => "abc-123..."
entry[:event]      # => the event object
entry[:published]  # => false

# Poll unpublished
outbox.poll(limit: 50)     # => [entry, ...]

# Mark as delivered
outbox.mark_published(entry[:id])

# Inspect
outbox.pending_count  # => 0
outbox.entries        # => all entries (published and unpublished)
outbox.clear          # => remove everything
```

## Poller API

```ruby
poller = Hecks::Outbox::OutboxPoller.new(outbox, event_bus)

# Drain all pending entries
count = poller.drain(limit: 100)   # => number published

# Stats
poller.stats  # => { published: 3, pending: 0 }
```

The poller accepts an optional `publisher:` keyword for custom delivery:

```ruby
poller = Hecks::Outbox::OutboxPoller.new(outbox, bus, publisher: ->(evt) {
  MyExternalBroker.send(evt)
})
```

## Production Notes

The in-memory outbox is suitable for development and testing. For production, implement an outbox adapter backed by your database (same transaction as the aggregate write) and run the poller in a background thread or separate process.
