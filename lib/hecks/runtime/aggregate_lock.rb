module Hecks
  module Runtime
    # A process-wide, striped mutex registry, keyed by `[domain, aggregate, id]`.
    # Serializes hydrate-through-save for adapters without `:optimistic_concurrency`.
    #
    # A lock suffices because those adapters (Heki, Memory) hold process-local data:
    # only threads of this process can write the same record.
    module AggregateLock
      @registry_lock = Mutex.new
      @locks = {}

      class << self
        # Returns the Mutex striped to one record, creating it on first use.
        #
        #   AggregateLock.for(domain, aggregate, id).synchronize { ... }
        #
        # @param domain [String] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate being dispatched
        # @param id [String, nil] the record id; nil locks by aggregate type alone, which
        #   is coarser but still correct
        # @return [Mutex] the mutex for this `[domain, aggregate, id]` key
        def for(domain, aggregate, id = nil)
          key = id.nil? ? [domain.to_s, aggregate.hecks_name] : [domain.to_s, aggregate.hecks_name, id.to_s]
          @registry_lock.synchronize { @locks[key] ||= Mutex.new }
        end
      end
    end
  end
end
