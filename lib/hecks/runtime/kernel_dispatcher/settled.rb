require "json"

module Hecks
  module Runtime
    class KernelDispatcher
      # What the kernel's store settled on, read back over the host protocol, and the reset that
      # returns the store to where it stood. A behaviors run reads a dispatched record through
      # `repository(domain, aggregate).find(id)` and resets the store between tests with `reset!`,
      # as it does on the in-process engine. Included into {KernelDispatcher}.
      module Settled
        # One record the kernel holds: its identity and its state, keyed by symbol.
        Record = Struct.new(:id, :state, keyword_init: true)

        # Reads one aggregate's records from the kernel's `instances` answer, whose keys are
        # `Domain::Aggregate#id`.
        class Repository
          # @param client [RustBuild::KernelClient] a connected client
          # @param prefix [String] `Domain::Aggregate`, the part of each key before `#`
          def initialize(client, prefix)
            @client = client
            @prefix = prefix
          end

          # @param id [String] the record's identity
          # @return [Record, nil] the record the kernel holds under `id`, or nil when it holds none
          def find(id)
            state = @client.call("instances" => true).fetch("instances", {})["#{@prefix}##{id}"]
            state && Record.new(id: id, state: JSON.parse(JSON.generate(state), symbolize_names: true))
          end
        end

        # @param domain [String] a domain name
        # @return [Bluebook::Declaration, nil] the described bluebook of that name
        def bluebook(domain) = registry.bluebook(domain)

        # @param domain [String] a domain name
        # @param aggregate [Bluebook::Aggregate] one of its aggregates
        # @return [Repository] a reader of the kernel's records of that aggregate
        def repository(domain, aggregate) = Repository.new(@client, "#{domain}::#{aggregate.name}")

        # Returns the kernel's store to the state the first reset found, and forgets the events.
        # The first call keeps a snapshot of the store; each later call restores it.
        #
        # @return [void]
        def reset!
          @client.call(@kept ? { "restore" => true } : { "snapshot" => true })
          @kept = true
          @events.clear
        end

        private

        # @return [Hash{String => String}] the bound caller's role and actor, as a step carries them
        def caller_fields
          bound = Caller.current
          return {} unless bound

          { "role" => bound.role, "actor_id" => bound.actor_id }.compact
        end
      end
    end
  end
end
