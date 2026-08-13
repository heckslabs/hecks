module Hecksagain
  module Ports
    module Persistence
      # THE NO-OP SAGA STORE — what `Registry#saga_persistence` hands
      # back for a domain whose resolved adapter doesn't implement the
      # (optional) saga-persistence capability: Memory, deliberately
      # (sagas stay in-memory-only, exactly as they always have), and
      # any `RemoteRuntime`-shaped adapter (Lambda; the real durability
      # for those lives on the other side of the call — Phase 1, not
      # here). `SagaInterpreter`'s hook points call through
      # `saga_persistence(domain)` unconditionally; this is what makes
      # that safe without a `respond_to?` check at every call site,
      # mirroring the same optional-capability shape
      # `Ports::Persistence::AppendOnly` already gives adapters that
      # don't implement `reset!`/`events`/`record_event`.
      class NullSagaStore
        def save_saga(**) = nil
        def delete_saga(**) = nil
        def each_saga(*) = nil
      end

      NULL_SAGA_STORE = NullSagaStore.new
    end
  end
end
