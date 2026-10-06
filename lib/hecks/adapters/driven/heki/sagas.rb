module Hecks
  module Adapters
    class Heki
      # The saga-checkpoint surface of the file-backed store: each call delegates to a
      # `SagaStore` kept in a sibling file pair, scoped by the adapter's domain name.
      module Sagas
        # Checkpoints one saga instance in a sibling file pair (`SagaStore`).
        #
        # @param process_manager [String, Symbol] the process manager's name, compared as
        #   `.to_s`
        # @param correlation [String, Symbol, Object] the instance's correlation value, compared
        #   as `.to_s`
        # @param state [String, Symbol] the saga's current state name, compared as `.to_s`
        # @param memory [Hash] the saga's working memory to persist
        # @param completed_compensations [Array] the ledger of completed compensable legs;
        #   `[]` when none
        # @return [Hash{String => Hash}] `SagaStore`'s internal records Hash after the write;
        #   callers ignore it
        def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
          checkpoint = { "state" => state.to_s, "memory" => memory, "completed_compensations" => completed_compensations }
          saga_store.save_saga(@domain, process_manager.to_s, correlation.to_s, checkpoint)
        end

        # Removes a finished saga instance's checkpoint; a missing one is not an error.
        #
        # @param process_manager [String, Symbol] the process manager's name, compared as
        #   `.to_s`
        # @param correlation [String, Symbol, Object] the instance's correlation value, compared
        #   as `.to_s`
        # @return [Hash{String => Hash}] `SagaStore`'s internal records Hash after the delete;
        #   callers ignore it
        def delete_saga(process_manager:, correlation:)
          saga_store.delete_saga(@domain, process_manager.to_s, correlation.to_s)
        end

        # Yields every checkpointed saga instance of this domain, for boot-time rehydration.
        #
        # @yieldparam process_manager [String] the process manager's name
        # @yieldparam correlation [String] the instance's correlation value
        # @yieldparam state [String] the saga's state name
        # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every
        #   depth
        # @yieldparam completed_compensations [Array] the completed-compensation ledger
        # @return [Enumerator, Hash{String => Hash}] an enumerator when no block is given
        def each_saga(&) = saga_store.each_saga(@domain, &)

        private

        def saga_store
          @saga_store ||= SagaStore.new(File.dirname(@path))
        end
      end
    end
  end
end
