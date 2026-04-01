# Hecks::SagaStore
#
# In-memory persistence for saga instances. Stores saga state keyed by
# saga_id. Swappable -- replace with Redis/SQL-backed store for production.
#
#   store = SagaStore.new
#   store.save("abc-123", { state: :running, completed: [0] })
#   store.find("abc-123")  # => { state: :running, completed: [0] }
#
module Hecks
  class SagaStore
    # @return [Hash{String => Hash}] all stored saga instances
    attr_reader :instances

    def initialize
      @instances = {}
    end

    # Persist a saga instance by ID.
    #
    # @param saga_id [String] unique saga correlation ID
    # @param data [Hash] saga state data
    # @return [Hash] the stored data
    def save(saga_id, data)
      @instances[saga_id.to_s] = data
    end

    # Look up a saga instance by ID.
    #
    # @param saga_id [String] unique saga correlation ID
    # @return [Hash, nil] the saga state, or nil if not found
    def find(saga_id)
      @instances[saga_id.to_s]
    end

    # Remove a saga instance by ID.
    #
    # @param saga_id [String] unique saga correlation ID
    # @return [Hash, nil] the removed data
    def delete(saga_id)
      @instances.delete(saga_id.to_s)
    end

    # Remove all stored saga instances.
    #
    # @return [void]
    def clear
      @instances.clear
    end
  end
end
