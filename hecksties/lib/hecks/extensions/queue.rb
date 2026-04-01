# HecksQueue
#
# Message queue extension for Hecks. Subscribes to the domain event bus
# and publishes every event as JSON to a queue adapter (e.g. RabbitMQ).
#
# The adapter must respond to #publish(routing_key, payload) or
# #call(event_json). If no adapter is provided, events are written
# to a JSON-lines file at queue_events.jsonl for consumption by
# external systems.
#
# Usage:
#   app = Hecks.boot(__dir__) do
#     extend :queue, adapter: :rabbitmq
#   end
#
# Or with a custom adapter:
#   app = Hecks.boot(__dir__) do
#     extend :queue, adapter: MyQueueAdapter.new
#   end
#
require "json"

Hecks.describe_extension(:queue,
  description: "Event queue publishing (RabbitMQ, file, custom adapter)",
  adapter_type: :driving,
  config: { adapter: { default: :file, desc: "Queue adapter (:rabbitmq, :file, or object)" } },
  wires_to: :event_bus)

Hecks.register_extension(:queue) do |domain_mod, domain, runtime|
  config = domain_mod.respond_to?(:connections) &&
    domain_mod.connections[:sends]&.find { |s| s[:name] == :queue }

  next unless config

  adapter = config[:adapter] || :file
  queue_adapter = resolve_queue_adapter(adapter, domain)

  runtime.event_bus.on_any do |event|
    event_name = Hecks::Utils.const_short_name(event)
    occurred = event.respond_to?(:occurred_at) ? event.occurred_at.iso8601 : Time.now.iso8601
    payload = { event: event_name, domain: domain.name, occurred_at: occurred }

    if queue_adapter.respond_to?(:publish)
      queue_adapter.publish(event_name, JSON.generate(payload))
    elsif queue_adapter.respond_to?(:call)
      queue_adapter.call(JSON.generate(payload))
    end
  end
end

module HecksQueue
  # File-based queue adapter — appends JSON lines to a file.
  # Useful for development and testing without a real broker.
  class FileAdapter
    def initialize(path)
      @path = path
    end

    def publish(_routing_key, payload)
      File.open(@path, "a") { |f| f.puts(payload) }
    end
  end

  # RabbitMQ adapter stub — logs to stdout. Replace with bunny gem
  # integration for production use.
  class RabbitMqAdapter
    def initialize(domain_name)
      @exchange = domain_name.downcase
    end

    def publish(routing_key, payload)
      $stdout.puts "[queue:#{@exchange}] #{routing_key}: #{payload}"
    end
  end
end

# Helper to resolve adapter symbol to an adapter instance.
def resolve_queue_adapter(adapter, domain)
  case adapter
  when :file
    HecksQueue::FileAdapter.new("queue_events.jsonl")
  when :rabbitmq
    HecksQueue::RabbitMqAdapter.new(domain.name)
  else
    adapter # assume it's a custom adapter object
  end
end
