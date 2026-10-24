module Hecks
  module Adapters
    class PostgresEra
      # Saga checkpoints. Rows keep `domain` as a column so domains sharing one schema stay
      # isolated. No lock here: `SagaInterpreter`'s own mutex already serializes in-process writers.
      module Sagas
        # The DDL for the checkpoint table.
        CREATE_SAGAS_SQL = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS hecks_saga_instances (
            domain               text NOT NULL,
            process_manager      text NOT NULL,
            correlation          text NOT NULL,
            state                text NOT NULL,
            memory               jsonb NOT NULL,
            completed_compensations  jsonb NOT NULL DEFAULT '[]'::jsonb,
            updated_at           timestamptz NOT NULL DEFAULT now(),
            PRIMARY KEY (domain, process_manager, correlation)
          )
        SQL

        # Checkpoints one saga instance, replacing the row for the same (domain, process manager,
        # correlation) if one exists.
        #
        # @param memory [Hash] the saga's memory, stored as JSON
        # @param completed_compensations [Array] compensable legs already completed, stored as JSON
        # @return [PG::Result] the upsert's result
        def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
          @db.exec_params(
            "INSERT INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, completed_compensations) " \
            "VALUES ($1, $2, $3, $4, $5, $6) " \
            "ON CONFLICT (domain, process_manager, correlation) DO UPDATE " \
            "SET state = EXCLUDED.state, memory = EXCLUDED.memory, " \
            "completed_compensations = EXCLUDED.completed_compensations, updated_at = now()",
            [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
             JSON.generate(completed_compensations)]
          )
        end

        # Removes a finished saga instance's checkpoint; a no-op when no such row exists.
        #
        # @return [PG::Result] the DELETE's result
        def delete_saga(process_manager:, correlation:)
          @db.exec_params(
            "DELETE FROM hecks_saga_instances WHERE domain = $1 AND process_manager = $2 AND correlation = $3",
            [@domain, process_manager.to_s, correlation.to_s]
          )
        end

        # Yields every saga checkpoint stored for this domain, so a booting registry can rehydrate.
        #
        # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, keys symbolized
        # @return [Enumerator, PG::Result] an enumerator when no block is given
        def each_saga
          return enum_for(:each_saga) unless block_given?

          @db.exec_params(
            "SELECT process_manager, correlation, state, memory, completed_compensations " \
            "FROM hecks_saga_instances WHERE domain = $1",
            [@domain]
          ).each do |row|
            yield row["process_manager"], row["correlation"], row["state"],
                  JSON.parse(row["memory"], symbolize_names: true),
                  JSON.parse(row["completed_compensations"] || "[]", symbolize_names: true)
          end
        end

        private

        def create_saga_table!
          @db.exec(CREATE_SAGAS_SQL)
          # Covers a table created before this column existed, where IF NOT EXISTS is a no-op.
          @db.exec("ALTER TABLE hecks_saga_instances ADD COLUMN IF NOT EXISTS completed_compensations jsonb " \
                   "NOT NULL DEFAULT '[]'::jsonb")
        end
      end
    end
  end
end
