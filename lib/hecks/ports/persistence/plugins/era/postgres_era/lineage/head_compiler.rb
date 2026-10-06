require_relative "chain_sql"
require_relative "sql_templates"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The read side of lineage: builds and maintains the head-snapshot
        # table and the compiled view/matview a query actually reads.
        module HeadCompiler
          include ChainSql
          include SqlTemplates

          # Backfill runs unconditionally after create: an existing journal
          # must never look empty just because its snapshot table is new.
          def ensure_head_snapshot!(storage_name, era)
            name = head_snapshot(storage_name, era)
            create_head_snapshot_table!(name) unless table_exists?(name)
            # Self-healing for a table created before this column existed;
            # a no-op once it and the relaxed constraint are already there.
            @db.exec("ALTER TABLE #{quote(name)} ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'save'")
            @db.exec("ALTER TABLE #{quote(name)} ALTER COLUMN state DROP NOT NULL")
            backfill_head_snapshot!(name, storage_name, era)
          end

          # Chunked via ResumableBackfill instead of one blocking
          # INSERT ... SELECT, so an ordinary reader or writer is never
          # blocked while a backfill is in flight.
          def backfill_head_snapshot!(name, storage_name, era)
            chunked_backfill!(
              name,
              source_sql: ->(cursor) { head_backfill_page_sql(cursor, storage_name, era) },
              upsert:     ->(rows) { upsert_head_snapshot_rows!(name, rows) }
            )
          end

          # Matches any relation kind via to_regclass, not only a table,
          # despite the name.
          def table_exists?(name)
            @db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name]).getvalue(0, 0) == "t"
          end

          # Runs the block inside a transaction, nesting via `SAVEPOINT` when one is already open.
          #
          # `@db.transaction` is a bare `BEGIN`/`COMMIT` with no savepoint nesting,
          # so calling it while already inside a transaction would commit
          # early; this uses a `SAVEPOINT` instead whenever one is already open.
          def nested_transaction(name, &)
            return @db.transaction(&) if @db.transaction_status == PG::PQTRANS_IDLE

            @db.exec("SAVEPOINT #{name}")
            begin
              yield
              @db.exec("RELEASE SAVEPOINT #{name}")
            rescue StandardError
              @db.exec("ROLLBACK TO SAVEPOINT #{name}")
              raise
            end
          end

          # Era 1's head is the snapshot table itself, verbatim — no ancestor
          # tail to reduce.
          def ensure_first_head!(storage_name)
            ensure_head_snapshot!(storage_name, 1)
            tokens = { head_view: quote(head_view(storage_name)), snapshot: quote(head_snapshot(storage_name, 1)) }
            @db.exec(format(FIRST_HEAD_VIEW_SQL, tokens))
          end

          # The matview bakes each ancestor's watermark in as a literal;
          # refreshing it incrementally or re-deriving the cut at query time
          # would leak post-cut ancestor writes into the head. Only rebuilding
          # the definition (mint, merge) may move the cut.
          def compile_head!(aggregate, era, label, edges, full: false)
            storage_name = aggregate.storage_name
            view = matview(storage_name, era, label)
            body = head_body_sql(aggregate, era, edges, full: full)
            @db.exec("CREATE MATERIALIZED VIEW #{quote(view)} AS\n#{body}\n")
            @db.exec("CREATE INDEX IF NOT EXISTS #{quote("#{view}_reduce_idx")} ON #{quote(view)} (aggregate_id, ordinal DESC)")

            ensure_head_snapshot!(storage_name, era)
            replace_head_view!(storage_name, era, view)
          end

          # The rule-compiling helpers live in Translation::RuleCompiler instead,
          # with no database connection, so Exporter's build-time SQL export can
          # call the exact same code these callers do.

          # Matches a view or materialized view only; a table of the same
          # name does not count.
          def view_exists?(name)
            # pg_table_is_visible, not information_schema, so this resolves
            # the name the same way search_path would rather than matching a
            # sibling domain's same-named view.
            @db.exec_params(
              "SELECT 1 FROM pg_class WHERE relname = $1 AND relkind IN ('v', 'm') " \
              "AND pg_table_is_visible(oid)",
              [name]
            ).ntuples.positive?
          end

          private

          # Locked, not a bare CREATE, so two first-time boots can't race;
          # nested_transaction lets this run standalone or inside mint's
          # own already-open transaction without ending it early.
          def create_head_snapshot_table!(name)
            nested_transaction("hecks_head_snapshot") do
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_head_snapshot:' || $1))", [name])
              next if table_exists?(name)

              @db.exec(format(HEAD_SNAPSHOT_SQL, table: quote(name)))
            end
          end

          def head_backfill_page_sql(cursor, storage_name, era)
            after_cursor = ("AND aggregate_id > #{text_literal(cursor)}" if cursor)
            format(HEAD_BACKFILL_SQL, journal: quoted_journal, era: era.to_i, aggregate: text_literal(storage_name),
                                      after_cursor: after_cursor, chunk_size: ResumableBackfill::CHUNK_SIZE)
          end

          def upsert_head_snapshot_rows!(name, rows)
            rows.each do |row|
              # Always 'save' — the source SQL filtered to operation = 'save' rows only.
              @db.exec_params(
                "INSERT INTO #{quote(name)} (id, ordinal, operation, state) VALUES ($1, $2, 'save', $3) " \
                "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
                "state = EXCLUDED.state WHERE #{quote(name)}.ordinal < EXCLUDED.ordinal",
                [row["id"], row["ordinal"], row["state"]]
              )
            end
          end

          def replace_head_view!(storage_name, era, view)
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
            tokens = { head_view: quote(head_view(storage_name)), view: quote(view),
                       snapshot: quote(head_snapshot(storage_name, era)) }
            @db.exec(format(HEAD_VIEW_SQL, tokens))
          end
        end
      end
    end
  end
end
