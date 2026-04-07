# HecksOutbox
#
# Outbox extension for reliable event publishing. When active, events
# are intercepted at the event bus level and stored in a local outbox
# instead of being delivered to listeners immediately. A synchronous
# poller drains the outbox after each command dispatch, publishing
# stored events to listeners and guaranteeing at-least-once delivery.
#
# This works with both dispatch paths: the command bus (app.run) and
# the aggregate shortcut methods (Pizza.create). Events always flow
# through the event bus publish method, which is wrapped by this extension.
#
# Usage:
#   app = Hecks.load(domain)
#   app.extend(:outbox, enabled: true)
#
#   Pizza.create(name: "Margherita")
#   Hecks.outbox.entries.size     # => 1 (stored + already drained)
#   Hecks.outbox.pending_count    # => 0 (poller drained it)
#   app.events.size               # => 1 (delivered via poller)
#
Hecks.describe_extension(:outbox,
  description: "Reliable event publishing via transactional outbox pattern",
  adapter_type: :driven,
  config: { enabled: { default: false, desc: "Must be explicitly enabled" } },
  wires_to: :event_bus)

Hecks.register_extension(:outbox) do |_domain_mod, _domain, runtime, **kwargs|
  # Only activate when explicitly requested. Passing any keyword argument
  # signals intent (e.g., app.extend(:outbox, enabled: true)).
  next if kwargs.empty?

  outbox = Hecks::Outbox::MemoryOutbox.new
  bus = runtime.event_bus

  # Wrap the event bus publish to store in outbox instead of delivering
  original_publish = bus.method(:publish)
  bus.define_singleton_method(:publish) do |event|
    outbox.store(event)
  end

  # Build a poller that uses the original publish to deliver events
  poller = Hecks::Outbox::OutboxPoller.new(outbox, bus, publisher: original_publish)

  # Drain the outbox after every command dispatch via middleware
  runtime.use(:outbox_poller) do |_cmd, next_handler|
    result = next_handler.call
    poller.drain
    result
  end

  # Expose outbox and poller on the Hecks module
  Hecks.instance_variable_set(:@_outbox, outbox)
  Hecks.instance_variable_set(:@_outbox_poller, poller)
  Hecks.define_singleton_method(:outbox) { @_outbox }
  Hecks.define_singleton_method(:outbox_poller) { @_outbox_poller }
end
