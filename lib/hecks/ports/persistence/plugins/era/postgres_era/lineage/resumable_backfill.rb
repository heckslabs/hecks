module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Chunked, lock-free, resumable backfill loop shared by the head-snapshot backfill and each
        # field-cache table's initial backfill.
        module ResumableBackfill
          CHUNK_SIZE = 5_000

          # Creates `hecks_backfill_progress`, the per-target cursor table, if absent.
          def ensure_backfill_progress_table!
            @db.exec(<<~SQL)
              CREATE TABLE IF NOT EXISTS hecks_backfill_progress (
                target     text PRIMARY KEY,
                cursor     text,
                completed  boolean NOT NULL DEFAULT false,
                updated_at timestamptz NOT NULL DEFAULT now()
              )
            SQL
          end

          # Fills `target` one committed chunk at a time, resuming from its stored cursor.
          #
          # `source_sql` takes the last id (nil before the first chunk) and returns a SELECT
          # with an ascending text `id` column, `id > cursor`, `LIMIT CHUNK_SIZE`. `upsert`
          # takes the chunk's PG::Result and runs in the cursor update's transaction.
          #
          # @raise [PG::Error] on a failed read or cursor update; `upsert` errors roll back
          def chunked_backfill!(target, source_sql:, upsert:)
            ensure_backfill_progress_table!
            loop do
              done = run_chunk!(target, source_sql: source_sql, upsert: upsert)
              break if done
            end
          end

          private

          # One chunk, one transaction. Progress is re-read under the lock: a concurrent booter may
          # have committed this chunk while we waited.
          def run_chunk!(target, source_sql:, upsert:)
            progress = backfill_progress(target)
            return true if progress[:completed]

            completed = false
            nested_transaction("hecks_backfill_chunk") do
              # Prefix is disjoint from the ordinal/era/head-snapshot lock keys, so a chunk
              # never blocks a write or a mint.
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_field_cache:' || $1))", [target])
              progress = backfill_progress(target)
              if progress[:completed]
                completed = true
                next
              end

              rows = @db.exec(source_sql.call(progress[:cursor]))
              if rows.ntuples.zero?
                upsert_backfill_progress!(target, cursor: progress[:cursor], completed: true)
                completed = true
                next
              end

              upsert.call(rows)
              completed = rows.ntuples < CHUNK_SIZE
              # `PG::Result#[]` rejects negative indexes, so index the last row explicitly.
              last_cursor = rows[rows.ntuples - 1]["id"]
              upsert_backfill_progress!(target, cursor: last_cursor, completed: completed)
            end
            completed
          end

          # `PG::Result#[]` raises IndexError out of range, so check `ntuples.zero?` before `[0]`.
          def backfill_progress(target)
            result = @db.exec_params(
              "SELECT cursor, completed FROM hecks_backfill_progress WHERE target = $1", [target]
            )
            return { cursor: nil, completed: false } if result.ntuples.zero?

            row = result[0]
            { cursor: row["cursor"], completed: row["completed"] == "t" }
          end

          def upsert_backfill_progress!(target, cursor:, completed:)
            @db.exec_params(
              "INSERT INTO hecks_backfill_progress (target, cursor, completed, updated_at) " \
              "VALUES ($1, $2, $3, now()) " \
              "ON CONFLICT (target) DO UPDATE SET cursor = EXCLUDED.cursor, " \
              "completed = EXCLUDED.completed, updated_at = EXCLUDED.updated_at",
              [target, cursor, completed]
            )
          end
        end
      end
    end
  end
end
