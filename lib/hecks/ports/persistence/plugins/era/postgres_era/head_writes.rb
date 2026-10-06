require "json"

module Hecks
  module Adapters
    class PostgresEra
      # The write path under the domain's lock: one journal row, then the head snapshot and every
      # field cache brought to the same ordinal inside the same transaction.
      module HeadWrites
        private

        def lock_writes!
          @db.exec_params(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            [@lineage.domain]
          )
        end

        def append_and_project!(entry)
          state_json = entry.state && JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, entry.state))
          ordinal = insert_journal_row(entry, state_json)
          entry.save? ? snapshot_save!(entry, ordinal, state_json) : snapshot_delete!(entry, ordinal)
          ordinal
        end

        def insert_journal_row(entry, state_json)
          @db.exec_params(
            "INSERT INTO #{@lineage.quoted_journal} (era, aggregate, aggregate_id, operation, state, mirrors) " \
            "VALUES ($1, $2, $3, $4, $5, $6) RETURNING ordinal",
            [@era, table, entry.id, entry.operation, state_json,
             entry.mirrors && JSON.generate(entry.mirrors)]
          )[0]["ordinal"]
        end

        def snapshot_save!(entry, ordinal, state_json)
          @db.exec_params(
            "INSERT INTO #{quoted_head_snapshot} (id, ordinal, operation, state) VALUES ($1, $2, 'save', $3) " \
            "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
            "state = EXCLUDED.state WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
            [entry.id, ordinal, state_json]
          )
          # Same transaction and ordinal, so every cache is exactly as current as the snapshot.
          @field_caches.each do |field, cache_table|
            @lineage.upsert_field_cache_row!(cache_table, entry.id, ordinal, state_json, query_expression(field))
          end
        end

        # A tombstone row, not a bare DELETE: without one, an ancestor era's saved row would win
        # the head's DISTINCT ON and the deleted record would read back. The ordinal guard keeps
        # a stale replayed delete from clobbering a newer save.
        def snapshot_delete!(entry, ordinal)
          @db.exec_params(
            "INSERT INTO #{quoted_head_snapshot} (id, ordinal, operation, state) VALUES ($1, $2, 'delete', NULL) " \
            "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
            "state = EXCLUDED.state WHERE #{quoted_head_snapshot}.ordinal < EXCLUDED.ordinal",
            [entry.id, ordinal]
          )
          @field_caches.each_value { |cache_table| @lineage.delete_field_cache_row!(cache_table, entry.id) }
        end
      end
    end
  end
end
