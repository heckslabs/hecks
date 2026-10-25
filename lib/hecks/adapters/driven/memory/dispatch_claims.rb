module Hecks
  module Adapters
    class Memory
      # The in-process record of saga dispatches already applied, keyed by the dispatch's own key,
      # held in the adapter's `@dispatch_claims`. See `Runtime::DispatchClaim`.
      module DispatchClaims
        # Whether the dispatch with this key has been applied.
        #
        # @param key [String] the dispatch key a saga leg stamped on the command
        # @return [Boolean] true once `dispatch_claim` has accepted the key
        def dispatch_applied?(key) = @dispatch_claims.key?(key)

        # Records that the dispatch with this key is being applied, refusing a second claim.
        #
        # @param key [String] the dispatch key a saga leg stamped on the command
        # @return [Boolean] true when the key was new and is now held; false when already held
        def dispatch_claim(key)
          return false if @dispatch_claims.key?(key)

          @dispatch_claims[key] = true
        end
      end
    end
  end
end
