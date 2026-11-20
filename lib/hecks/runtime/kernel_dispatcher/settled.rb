require_relative "repository"

module Hecks
  module Runtime
    class KernelDispatcher
      # What the kernel's store settled on, read back over the host protocol, and the reset that
      # returns the store to where it stood. A behaviors run reads a dispatched record through
      # `repository(domain, aggregate).find(id)` and resets the store between tests with `reset!`,
      # as it does on the in-process engine. Included into {KernelDispatcher}.
      module Settled
        # One record as the kernel's `instances` answer holds it: its identity and its raw state,
        # keyed by symbol, before any hydration. A reader that wants the kernel's own shape, such
        # as the sequence generator's, builds these; {Repository} answers `Runtime::Instance`.
        Record = Struct.new(:id, :state, keyword_init: true)

        # @param domain [String] a domain name
        # @param aggregate [Bluebook::Aggregate] one of its aggregates
        # @return [Repository] a reader of the kernel's records of that aggregate
        def repository(domain, aggregate) = Repository.new(@client, domain, aggregate)

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
