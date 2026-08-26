module Hecks
  module Runtime
    # A PROCESS-WIDE, STRIPED MUTEX REGISTRY — the concurrency-control
    # mechanism for every adapter that does NOT declare
    # `:optimistic_concurrency` (Heki, Memory today; see
    # `CommandInterpreter#call`/`EntityInterpreter#call`, which choose
    # between this and Postgres's CAS+retry purely off
    # `repository.capabilities`).
    #
    # WHY A LOCK SUFFICES HERE AND CAS IS NOT NEEDED: both adapters hold
    # process-local data. `Adapters::Memory.tenant_capable?`'s own comment
    # states the confirmed fact this relies on — two `Runtime.boot` calls
    # get two entirely separate adapter instances; there is never a SECOND
    # PROCESS writing the same Heki file or the same Memory Hash, only
    # possibly other THREADS within this one process. A `Mutex` held for
    # the full hydrate-through-save critical section closes the identical
    # lost-update gap CAS closes for Postgres, with no schema, no version
    # column, and no retry loop — the second thread simply doesn't start
    # its own hydrate until the first thread's save has landed.
    #
    # STRIPED, NOT ONE GLOBAL LOCK: keyed by `[domain, aggregate.hecks_name,
    # id]`, so two dispatches against two DIFFERENT records never block
    # each other. The registry Hash itself is guarded by its own top-level
    # Mutex only for the moment a new per-key Mutex is created — two
    # threads locking DIFFERENT keys for the first time never wait on one
    # another beyond that brief creation window.
    module AggregateLock
      @registry_lock = Mutex.new
      @locks = {}

      class << self
        # `AggregateLock.for(domain, aggregate, id).synchronize { ... }`
        # `id: nil` — identity could not be resolved yet (see
        # `Identity.best_effort`) — locks by aggregate TYPE alone, coarser
        # (every record of this aggregate serializes against every other)
        # but still correct: it can only ever make dispatch MORE
        # conservative than a resolved id would.
        def for(domain, aggregate, id = nil)
          key = id.nil? ? [domain.to_s, aggregate.hecks_name] : [domain.to_s, aggregate.hecks_name, id.to_s]
          @registry_lock.synchronize { @locks[key] ||= Mutex.new }
        end
      end
    end
  end
end
