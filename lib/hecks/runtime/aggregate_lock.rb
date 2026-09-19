module Hecks
  module Runtime
    # **A process-wide, striped mutex registry** — the concurrency-control
    # mechanism for every adapter that does not declare
    # `:optimistic_concurrency` (Heki, Memory today; see
    # `CommandInterpreter#call`/`EntityInterpreter#call`, which choose
    # between this and Postgres's CAS+retry purely off
    # `repository.capabilities`).
    #
    # Why a lock suffices here and CAS is not needed: both adapters hold
    # process-local data. `Adapters::Memory.tenant_capable?`'s own comment
    # states the confirmed fact this relies on — two `Runtime.boot` calls
    # get two entirely separate adapter instances; there is never a second
    # process writing the same Heki file or the same Memory Hash, only
    # possibly other threads within this one process. A `Mutex` held for
    # the full hydrate-through-save critical section closes the identical
    # lost-update gap CAS closes for Postgres, with no schema, no version
    # column, and no retry loop — the second thread simply doesn't start
    # its own hydrate until the first thread's save has landed.
    #
    # **Striped, not one global lock**: keyed by `[domain, aggregate.hecks_name,
    # id]`, so two dispatches against two different records never block
    # each other. The registry Hash itself is guarded by its own top-level
    # Mutex only for the moment a new per-key Mutex is created — two
    # threads locking different keys for the first time never wait on one
    # another beyond that brief creation window.
    module AggregateLock
      @registry_lock = Mutex.new
      @locks = {}

      class << self
        # Returns the Mutex striped to one record, creating it on first use.
        #
        # `AggregateLock.for(domain, aggregate, id).synchronize { ... }`
        # `id: nil` — identity could not be resolved yet (see
        # `Identity.best_effort`) — locks by aggregate type alone, coarser
        # (every record of this aggregate serializes against every other)
        # but still correct: it can only ever make dispatch more
        # conservative than a resolved id would.
        #
        # @param domain [String] the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate being dispatched
        # @param id [String, nil] the resolved record id, or nil to stripe by aggregate type
        #   alone
        # @return [Mutex] the mutex for this `[domain, aggregate, id]` key, held for the full
        #   hydrate-through-save critical section
        def for(domain, aggregate, id = nil)
          key = id.nil? ? [domain.to_s, aggregate.hecks_name] : [domain.to_s, aggregate.hecks_name, id.to_s]
          @registry_lock.synchronize { @locks[key] ||= Mutex.new }
        end
      end
    end
  end
end
