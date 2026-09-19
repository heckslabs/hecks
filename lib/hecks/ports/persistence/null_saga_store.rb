module Hecks
  module Ports
    module Persistence
      # **The no-op saga store** — what `Registry#saga_persistence` hands
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
        # Accepts and discards a saga checkpoint, whatever keywords it carries.
        #
        # @return [nil] always; nothing is stored
        def save_saga(**) = nil

        # Accepts and ignores a request to forget a saga.
        #
        # @return [nil] always; there is nothing to delete
        def delete_saga(**) = nil

        # Yields nothing, because no saga is ever stored here.
        #
        # @return [nil] always; a block, if given, is never called
        def each_saga(*) = nil
      end

      NULL_SAGA_STORE = NullSagaStore.new
    end
  end
end
