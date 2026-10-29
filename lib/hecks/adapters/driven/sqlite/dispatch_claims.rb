module Hecks
  module Adapters
    class Sqlite
      # Saga dispatches already applied, one row per dispatch key in the aggregate's own database
      # file so a claim joins the save's transaction. See `Runtime::DispatchClaim`.
      module DispatchClaims
        # Whether the dispatch with this key has been applied.
        #
        # @param key [String] the dispatch key a saga leg stamped on the command
        # @return [Boolean] true once `dispatch_claim` has accepted the key
        def dispatch_applied?(key)
          !@db.get_first_row("SELECT 1 FROM hecks_dispatch_claims WHERE claim_key = ?", [key]).nil?
        end

        # Records that the dispatch with this key is being applied, refusing a second claim.
        #
        # @param key [String] the dispatch key a saga leg stamped on the command
        # @return [Boolean] true when the key was new and is now held; false when already held
        # @raise [SQLite3::Exception] if the insert fails
        def dispatch_claim(key)
          @db.execute("INSERT OR IGNORE INTO hecks_dispatch_claims (claim_key, claimed_at) VALUES (?, ?)",
                      [key, Time.now.utc.iso8601])
          @db.changes.positive?
        end
      end
    end
  end
end
