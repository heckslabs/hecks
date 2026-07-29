module Hecksagain
  module Ports
    module Persistence
      # `mirrors` is durable replication intent.  It is part of the same
      # append as the authoritative state, never a second outbox store.
      Entry = Struct.new(:operation, :id, :state, :mirrors, keyword_init: true) do
        def save? = operation == "save"
        def delete? = operation == "delete"
      end

      # Makes append-before-projection a port invariant. Adapters retain
      # control of their durable format, but every one must accept the same
      # entry stream and materialize current state from it.
      class AppendOnly
        attr_reader :adapter
        def aggregate = @adapter.aggregate

        def initialize(adapter)
          @adapter = adapter
          required = %i[append project entries]
          missing = required.reject { |method| adapter.respond_to?(method) }
          raise Runtime::WiringError, "#{adapter.class} does not implement append-only persistence: #{missing.join(', ')}" unless missing.empty?
        end

        def find(id) = @adapter.find(id)
        def all = @adapter.all
        def count = @adapter.count
        def entries = @adapter.entries
        def reset!
          raise Runtime::WiringError, "append-only adapter cannot reset" unless @adapter.respond_to?(:reset!)
          @adapter.reset!
        end
        def events = @adapter.events if @adapter.respond_to?(:events)

        # An append is durable before a projection is attempted. Replaying the
        # log restores a snapshot/table after a crash in that small window.
        def recover!
          entries.each { |entry| project(entry) }
          self
        end

        def append(entry) = @adapter.append(entry)
        def project(entry) = @adapter.project(entry)

        def save(instance)
          entry = Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          append(entry)
          project(entry)
          instance
        end

        def delete(id)
          return false unless find(id)

          entry = Entry.new(operation: "delete", id: id.to_s, state: nil)
          append(entry)
          project(entry)
          true
        end

        def record_event(event) = @adapter.record_event(event) if @adapter.respond_to?(:record_event)
        def query_read_model(domain, model, args, bluebook = nil)
          return unless @adapter.respond_to?(:query_read_model)

          @adapter.query_read_model(domain, model, args, bluebook)
        end
      end
    end
  end
end
