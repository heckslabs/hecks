module Hecks
  module Adapters
    class Sqlite
      # The optional saga-persistence capability's own operations (§2/§4)
      # — split out of the `Sqlite` class body only to keep it under its
      # line budget; every method here stays public on `Sqlite` instances
      # exactly as if it were still defined there.
      module SagaOperations
        # Replaces one saga instance's checkpoint, keyed by domain, process manager and
        # correlation.
        #
        # ── the optional saga-persistence capability (§2) — reuses the
        # DDL every SQLite-backed aggregate table already lives beside
        # (`create_saga_table!`, `Sqlite::SchemaBuilder`, shared with D1).
        # SQLite's `resolve_path` defaults to one `.db` file per
        # aggregate unless a domain shares one `database` setting across
        # its aggregates — since saga persistence resolves through
        # whichever adapter instance backs the domain's first aggregate
        # (`Registry#saga_persistence`), this table ends up living inside
        # that one aggregate's own file by default. Correct and durable
        # either way; a domain that wants an obviously-named saga store
        # already gets one by sharing `database` across its aggregates,
        # the recommended, common case.
        #
        # @param process_manager [String, Symbol] the process manager's name
        # @param correlation [String, Object] the instance's correlation value, stored as
        #   `correlation.to_s`
        # @param state [String, Symbol] the saga's current state name
        # @param memory [Hash] the saga's memory; must be JSON-serializable
        # @param completed_compensations [Array] the ledger of completed compensable legs; must
        #   be JSON-serializable
        # @return [Array] the statement's empty result rows; callers ignore it
        # @raise [SQLite3::Exception] if the statement fails
        def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
          @db.execute(
            "INSERT OR REPLACE INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, " \
            "completed_compensations) VALUES (?, ?, ?, ?, ?, ?)",
            [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
             JSON.generate(completed_compensations)]
          )
        end

        # Removes a finished saga instance's checkpoint; a missing row is not an error.
        #
        # @param process_manager [String, Symbol] the process manager's name
        # @param correlation [String, Object] the instance's correlation value, matched as
        #   `correlation.to_s`
        # @return [Array] the statement's empty result rows; callers ignore it
        # @raise [SQLite3::Exception] if the statement fails
        def delete_saga(process_manager:, correlation:)
          @db.execute(
            "DELETE FROM hecks_saga_instances WHERE domain = ? AND process_manager = ? AND correlation = ?",
            [@domain, process_manager.to_s, correlation.to_s]
          )
        end

        # Yields every checkpointed saga instance of this adapter's domain, for
        # `Registry#rehydrate_sagas!` to restore at boot.
        #
        # @yieldparam process_manager [String] the process manager's name
        # @yieldparam correlation [String] the instance's correlation value
        # @yieldparam state [String] the saga's state name
        # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every depth
        # @yieldparam completed_compensations [Array] the completed-compensation ledger, `[]`
        #   when the column is NULL
        # @return [Enumerator, Array<Hash>] an enumerator over the same five values when no
        #   block is given; otherwise the raw result rows
        # @raise [SQLite3::Exception] if the statement fails
        def each_saga
          return enum_for(:each_saga) unless block_given?

          @db.execute(
            "SELECT process_manager, correlation, state, memory, completed_compensations " \
            "FROM hecks_saga_instances WHERE domain = ?",
            [@domain]
          ).each do |row|
            yield row["process_manager"], row["correlation"], row["state"],
                  JSON.parse(row["memory"], symbolize_names: true),
                  JSON.parse(row["completed_compensations"] || "[]", symbolize_names: true)
          end
        end
      end
    end
  end
end
