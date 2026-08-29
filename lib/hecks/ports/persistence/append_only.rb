require_relative "../../runtime/registry"
require_relative "execution"

module Hecks
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
          unless missing.empty?
            raise Runtime::WiringError,
                  "#{adapter.class} does not implement append-only persistence: #{missing.join(', ')}"
          end
        end

        def find(id) = @adapter.find(id)
        def all(**) = @adapter.all(**)
        def count = @adapter.count
        def entries = @adapter.entries

        def capabilities
          return [] unless @adapter.respond_to?(:persistence_capabilities)

          Array(@adapter.persistence_capabilities).map(&:to_sym).freeze
        end

        def reset!
          raise Runtime::WiringError, "append-only adapter cannot reset" unless @adapter.respond_to?(:reset!)

          @adapter.reset!
        end

        # NOT an endless `def events = ... if ...` — that modifier binds to
        # the WHOLE `def`, not just its body, so it evaluates against
        # `@adapter` while `@adapter` is still nil (class-body time,
        # before `initialize` ever runs) and silently skips defining the
        # method at all. Found live: nothing in this codebase called
        # `AppendOnly#events` before Memory got a `reset!` test that did.
        def events
          @adapter.events if @adapter.respond_to?(:events)
        end

        # An append is durable before a projection is attempted. Replaying the
        # log restores a snapshot/table after a crash in that small window.
        def recover!
          entries.each { |entry| project(entry) }
          self
        end

        def append(entry) = @adapter.append(entry)
        def project(entry) = @adapter.project(entry)

        # Returns an `Outcome`, not a bare `Instance` — every call site
        # (`CommandInterpreter`/`EntityInterpreter`'s own `step_save`,
        # `RebuildSweep#refresh`) reads it that way.
        #
        # `expected_version:` requests optimistic-concurrency CAS — commit
        # only if the stored record's version still matches what THIS
        # instance was read at. It is `nil` both when a caller explicitly
        # doesn't want CAS (`RebuildSweep#refresh`'s own projection-field
        # touch-up, which has no `given` to protect) and when the instance
        # is brand new (never read from storage, so `instance.version` is
        # nil) — both cases fall through to the plain, unconditional
        # `project(entry)` below, byte-for-byte today's behavior. Only an
        # adapter that both receives a non-nil `expected_version` AND
        # declares `:optimistic_concurrency` gets CAS treatment; every
        # other adapter/call site is unaffected.
        def save(instance, expected_version: nil)
          entry = Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          append(entry)
          if expected_version && capabilities.include?(:optimistic_concurrency)
            saved = @adapter.project(entry, expected_version: expected_version)
            return Outcome.new(status: :stale, instance: instance) if saved.nil?

            return Outcome.new(status: :saved, instance: saved)
          end
          saved = @adapter.project(entry)
          Outcome.new(status: :saved, instance: saved || instance)
        end

        def atomic_put(instance, insert_only: false)
          unless capabilities.include?(:atomic_put) && @adapter.respond_to?(:atomic_put)
            raise Runtime::WiringError,
                  "#{@adapter.class} advertises no atomic_put persistence capability"
          end

          entry = Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          status = @adapter.atomic_put(entry, insert_only: insert_only)
          Outcome.new(status: status, instance: instance)
        end

        def delete(id)
          return false unless find(id)

          entry = Entry.new(operation: "delete", id: id.to_s, state: nil)
          append(entry)
          project(entry)
          true
        end

        # NOT an endless `def record_event = ... if ...` — same gotcha as
        # `events` above, and it bit for real here: this guard evaluated
        # against `@adapter` at class-body time (nil, always false), so
        # `record_event` was never defined at all. `emission.rb`'s own
        # `repository.record_event(event) if repository.respond_to?(:record_event)`
        # therefore never fired for any adapter, ever — every declared
        # `emits` was computed and reported in `registry.event_log` (an
        # in-process array, gone at exit) but never durably recorded.
        # Caught because a live tail of a domain's own persisted events
        # found nothing to tail. `sqlite_spec.rb`/`postgres_spec.rb`/
        # `postgres_era_spec.rb` all call `adapter.record_event` directly,
        # bypassing this wrapper — which is exactly why no spec noticed.
        def record_event(event)
          @adapter.record_event(event) if @adapter.respond_to?(:record_event)
        end

        def query_read_model(domain, model, args, bluebook = nil)
          return unless @adapter.respond_to?(:query_read_model)

          @adapter.query_read_model(domain, model, args, bluebook)
        end
      end
    end
  end
end
