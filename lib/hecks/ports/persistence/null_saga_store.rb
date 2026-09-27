module Hecks
  module Ports
    module Persistence
      # A saga store that keeps nothing, for adapters without the optional saga-persistence
      # capability; callers call through it unconditionally instead of checking `respond_to?`.
      class NullSagaStore
        # Discards the checkpoint.
        def save_saga(**) = nil

        # Ignores the request; there is nothing to delete.
        def delete_saga(**) = nil

        # Yields nothing, because no saga is ever stored here.
        def each_saga(*) = nil
      end

      NULL_SAGA_STORE = NullSagaStore.new
    end
  end
end
