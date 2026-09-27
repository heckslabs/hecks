module Hecks
  module Adapters
    # Deterministic `identity_generation` fulfillment: an incrementing counter instead of a UUID.
    # State is class-level, so specs call `reset!` to restart at 1.
    module SequentialIdentity
      module_function

      # Returns the next id in the sequence, starting at `"1"`.
      #
      # @return [String] the incremented counter, as a decimal string
      def uuid
        @count = (@count || 0) + 1
        @count.to_s
      end

      # Resets the counter to zero, so the next `#uuid` call returns `"1"`.
      #
      # @return [void]
      def reset! = @count = 0
    end
  end
end
