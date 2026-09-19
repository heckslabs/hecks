module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The one chunked, lock-free, resumable backfill loop — shared by
        # `backfill_head_snapshot!` (era 1's head-snapshot backfill) and
        # every field-cache table's own initial backfill. Governing
        # principle 1
        # (docs/implemented/postgres-era-adapter-split-plan.md): no
        # operation this plan touches may hold a lock across a scan whose
        # duration scales with table size — a single `INSERT ... SELECT`
        # over the whole journal (the one-shot form of
        # `backfill_head_snapshot!`) is exactly that, and so is a naive
        # "populate every cache row in one statement" field-cache backfill.
        #
        # ## The shape
        #
        # Read one bounded chunk (real rows, real ordinals) with
        # a plain SELECT — no lock held across it, so an ordinary reader or
        # writer is never blocked by a backfill in progress — then upsert
        # that chunk under the same transactionally-scoped advisory lock +
        # ordinal-guard idiom `append`'s own snapshot upsert already uses
        # (`WHERE ordinal < EXCLUDED.ordinal`), then persist a cursor
        # before moving to the next chunk. Repeat until a chunk reads back
        # short of a full page — that page was the last one.
        #
        # ## Resumable, not merely restartable
        #
        # A crash (or a second
        # concurrent boot) mid-backfill leaves the cursor exactly where the
        # last committed chunk left it — `hecks_backfill_progress` is
        # updated in the same transaction as the chunk's own upsert, so
        # cursor and data can never observably disagree (see
        # `run_chunk!`). The next attempt reads that cursor and continues;
        # it does not rescan what a prior attempt already committed.
        # Restartable would also be correct here (every upsert is
        # idempotent and ordinal-guarded — rerunning an already-done chunk
        # from id 1 changes nothing) but wastes real work on a large
        # table; resumability is what keeps a crash near the end of a
        # large backfill cheap to recover from instead of starting over.
        #
        # ## The lock key
        #
        # The lock key prefix is `hecks_field_cache:` — deliberately
        # disjoint from the three families already in use elsewhere in
        # this adapter (`hecks_ordinal:`, `hecks_eras:`,
        # `hecks_head_snapshot:` — see lineage.rb/head_compiler.rb/
        # mint_transaction.rb/tail_merge.rb) so a backfill chunk never
        # contends with a plain write, a mint, or a snapshot-table's own
        # first-creation lock. It is held for exactly one chunk's own
        # transaction, never across the whole backfill — two concurrent
        # backfillers of the same target simply take turns one chunk at a
        # time rather than racing to duplicate work; neither blocks an
        # unrelated reader or writer for even an instant.
        module ResumableBackfill
          CHUNK_SIZE = 5_000

          # Creates `hecks_backfill_progress`, the table of per-target backfill cursors, if absent.
          #
          # Idempotent, unguarded — same idiom as every other DDL helper
          # in this file tree (`ensure_head_snapshot!` et al.): cheap,
          # runs on every boot, only ever does real work once.
          #
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the DDL
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
          # Drives `target` (an already-created, currently-empty-or-
          # partially-filled table) through chunks until a source read
          # comes back short of `CHUNK_SIZE` rows. Two distinct callables,
          # not one — a head-snapshot row and a field-cache row carry
          # different columns (`state` jsonb vs. a single extracted
          # `value`), so there is no one generic "upsert this row" shape
          # to share; only the loop, the lock, and the cursor are generic.
          #
          #   source_sql.call(cursor) — given the last-processed id (nil
          #     before the first chunk), returns a SQL SELECT whose result
          #     has an `id` column (text, ordered ascending) plus whatever
          #     other columns `upsert` below needs. Must read `id >
          #     cursor` (or unconditional when cursor is nil), `ORDER BY
          #     id`, `LIMIT CHUNK_SIZE` — the caller owns the actual
          #     column list/source tables; this method only owns the loop,
          #     the lock, and the cursor.
          #
          #   upsert.call(rows) — given the PG::Result of one chunk's
          #     read, performs the actual guarded upsert into `target` and
          #     returns nothing meaningful; runs inside the same
          #     transaction/advisory-lock scope as the cursor update below,
          #     so a crash between "wrote the chunk" and "advanced the
          #     cursor" is impossible — they commit together or not at
          #     all.
          #
          # @param target [String] unquoted name of the table to fill; also the progress row's key
          #   and the advisory-lock key
          # @param source_sql [#call] callable given the cursor (`String` id of the last row
          #   processed, nil before the first chunk) that returns the chunk's SELECT as a `String`
          # @param upsert [#call] callable given one chunk's `PG::Result` that writes it into
          #   `target`; its return value is ignored
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the progress-table DDL, a source read, or a
          #   cursor update; whatever `upsert` raises propagates too, rolling back that chunk
          def chunked_backfill!(target, source_sql:, upsert:)
            ensure_backfill_progress_table!
            loop do
              done = run_chunk!(target, source_sql: source_sql, upsert: upsert)
              break if done
            end
          end

          private

          # One chunk, one transaction, one short-held lock. Re-reads
          # progress after acquiring the lock (not just before) — a second
          # concurrent booter may have already finished this exact chunk
          # (or the whole backfill) while this process was waiting for the
          # lock; without the re-read, it would redundantly reprocess a
          # chunk another process just committed. Harmless either way
          # (idempotent, ordinal-guarded) but the re-read is what keeps
          # two concurrent boots from both doing the full scan instead of
          # splitting it.
          def run_chunk!(target, source_sql:, upsert:)
            progress = backfill_progress(target)
            return true if progress[:completed]

            completed = false
            nested_transaction("hecks_backfill_chunk") do
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
              # `PG::Result#[]` supports neither an out-of-range index nor
              # a negative one (unlike a plain Ruby Array) — same trap as
              # `backfill_progress` above, the explicit last-index form.
              last_cursor = rows[rows.ntuples - 1]["id"]
              upsert_backfill_progress!(target, cursor: last_cursor, completed: completed)
            end
            completed
          end

          # `PG::Result#[]` raises IndexError on an out-of-range index —
          # unlike a plain Ruby Array, it does not return nil — so the
          # entirely ordinary case of "no progress row exists yet" (every
          # target's very first check) cannot be read via a bare `[0]`.
          # `ntuples.zero?` first, always.
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
