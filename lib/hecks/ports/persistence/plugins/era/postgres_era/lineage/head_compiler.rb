require_relative "../../../../../../naming"
require_relative "../../translation/rule_compiler"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The read side of lineage: builds and maintains the head-snapshot
        # table and the compiled view/matview a query actually reads.
        module HeadCompiler
          # Backfill runs unconditionally after create: an existing journal
          # must never look empty just because its snapshot table is new.
          def ensure_head_snapshot!(storage_name, era)
            name = head_snapshot(storage_name, era)
            unless table_exists?(name)
              # Locked, not a bare CREATE, so two first-time boots can't race;
              # nested_transaction lets this run standalone or inside mint's
              # own already-open transaction without ending it early.
              nested_transaction("hecks_head_snapshot") do
                @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_head_snapshot:' || $1))", [name])
                next if table_exists?(name)

                # A delete upserts a tombstone (operation = 'delete', state
                # NULL) instead of removing the row, so it still outranks a
                # stale ancestor `save` row by ordinal under DISTINCT ON.
                @db.exec(<<~SQL)
                  CREATE TABLE #{quote(name)} (
                    id        text PRIMARY KEY,
                    ordinal   bigint NOT NULL,
                    operation text NOT NULL DEFAULT 'save',
                    state     jsonb
                  )
                SQL
              end
            end
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
              source_sql: lambda do |cursor|
                <<~SQL
                  SELECT id, ordinal, state FROM (
                    SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, ordinal, operation, state
                    FROM #{quoted_journal}
                    WHERE era = #{era.to_i} AND aggregate = #{text_literal(storage_name)}
                    #{"AND aggregate_id > #{text_literal(cursor)}" if cursor}
                    ORDER BY aggregate_id, ordinal DESC
                  ) latest WHERE operation = 'save' ORDER BY id LIMIT #{ResumableBackfill::CHUNK_SIZE}
                SQL
              end,
              upsert:     lambda do |rows|
                rows.each do |row|
                  # Always 'save' — source_sql above already filtered to
                  # operation = 'save' rows only.
                  @db.exec_params(
                    "INSERT INTO #{quote(name)} (id, ordinal, operation, state) VALUES ($1, $2, 'save', $3) " \
                    "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
                    "state = EXCLUDED.state WHERE #{quote(name)}.ordinal < EXCLUDED.ordinal",
                    [row["id"], row["ordinal"], row["state"]]
                  )
                end
              end
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
            # WHERE operation = 'save' excludes delete tombstones, whose
            # state is NULL, so a deleted id falls out of the head instead
            # of resolving to a nil state.
            @db.exec(<<~SQL)
              CREATE OR REPLACE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM #{quote(head_snapshot(storage_name, 1))} WHERE operation = 'save'
            SQL
          end

          # Reduces the tail before chaining edges over it, not after: every
          # reader already reduces to latest-per-id, so translating a
          # superseded entry would be wasted work. `era` survives the
          # reduction because each edge's case still needs it.
          def latest_per_id(tail)
            return tail if tail.to_s.empty?

            "SELECT DISTINCT ON (aggregate_id) ordinal, era, aggregate, aggregate_id, operation, state " \
              "FROM (#{tail}) tail_entries ORDER BY aggregate_id, ordinal DESC"
          end

          # Builds era N by layering its own last edge onto era N-1's existing
          # matview, instead of re-deriving from raw history; returns nil
          # (falling back to chain_sql) whenever that shortcut can't honestly
          # apply. `edges.size != era - 1` guards names_by_era's own
          # assumption that `edges` is the full chain reaching `era` — a
          # shorter chain here would index names[:storage] out of bounds
          # rather than safely falling back.
          # rubocop:disable-next Metrics/CyclomaticComplexity
          # rubocop:disable-next Metrics/PerceivedComplexity
          def layered_chain_sql(aggregate, era, edges)
            return nil if era < 3 || edges.size < 2 || edges.size != era - 1

            held = eras
            prior = held.find { |candidate| candidate[:ordinal] == era - 1 }
            return nil unless prior && prior[:label]

            prior_view = matview(aggregate.storage_name, era - 1, prior[:label])
            return nil unless view_exists?(prior_view)

            names = names_by_era(aggregate, edges)
            cut = held.find { |candidate| candidate[:ordinal] == era }&.dig(:watermark)
            declared = edges.last[:translation].for_aggregate(names[:current][edges.size])
            expression = declared ? Translation::RuleCompiler.compile_rules(declared) : "state"
            id_column = if Translation::RuleCompiler.rekeyed?(declared)
                          Translation::RuleCompiler.id_case("operation = 'save'",
                                                            declared)
                        else
                          "aggregate_id"
                        end

            <<~SQL
              WITH layered AS (
                SELECT DISTINCT ON (aggregate_id) ordinal, aggregate_id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(prior_view)}
                  UNION ALL
                  SELECT ordinal, aggregate_id, operation, state FROM #{quoted_journal}
                  WHERE era = #{era - 1} AND aggregate = #{text_literal(names[:storage][era - 2])}#{" AND ordinal <= #{cut}" if cut}
                ) layers ORDER BY aggregate_id, ordinal DESC
              )
              SELECT ordinal, #{id_column}, operation,
                     CASE WHEN operation = 'save' THEN #{expression} ELSE state END AS state
              FROM layered
            SQL
          end

          # Chains the original edges in mint order rather than flattening them
          # into one rule set: edge 1 renaming A→B then edge 2 renaming C→A
          # has no single phase order that applies both correctly.
          def chain_sql(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = latest_per_id(ancestor_tail_sql(names, era))
            chain = edges.each_with_index.map do |edge, index|
              declared = edge[:translation].for_aggregate(names[:current][index + 1])
              expression = declared ? Translation::RuleCompiler.compile_rules(declared) : "state"
              guard = "era <= #{index + 1} AND operation = 'save'"
              id_column = if Translation::RuleCompiler.rekeyed?(declared)
                            Translation::RuleCompiler.id_case(guard,
                                                              declared)
                          else
                            "aggregate_id"
                          end
              "edge_#{index + 1} AS (SELECT ordinal, era, #{id_column}, operation, " \
                "CASE WHEN #{guard} THEN #{expression} ELSE state END AS state " \
                "FROM #{index.zero? ? "tail" : "edge_#{index}"})"
            end

            <<~SQL
              WITH tail AS (#{tail}),
              #{chain.join(",\n")}
              SELECT ordinal, aggregate_id, operation, state FROM edge_#{edges.size}
            SQL
          end

          # Reads through head_body_sql — the same layered-or-full choice
          # compile_head! makes at mint time — so a preview can't silently
          # drift from what a real mint will materialize.
          def translated_latest(aggregate, era, edges)
            latest_of(head_body_sql(aggregate, era, edges))
          end

          # The untranslated ancestor tail, latest entry per id — the "before"
          # side of a per-rule preservation check.
          def ancestor_latest(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = ancestor_tail_sql(names, era)
            return {} if tail.empty?

            latest_of("SELECT ordinal, era, aggregate_id, operation, state FROM (#{tail}) tail_rows")
          end

          # Reduces to newest entry per aggregate id, dropping any id whose
          # newest entry is a delete rather than returning it with a nil state.
          def latest_of(sql)
            rows = @db.exec(<<~SQL)
              SELECT aggregate_id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state
                FROM (#{sql}) chained ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
            rows.to_h { |row| [row["aggregate_id"], JSON.parse(row["state"])] }
          end

          # The one place that picks layered vs full, so a preview
          # (translated_latest) can never approve a branch the real mint
          # doesn't take. `full:` mirrors compile_head!'s own default;
          # tail_merge is the one caller that forces it true.
          def head_body_sql(aggregate, era, edges, full: false)
            return chain_sql(aggregate, era, edges) if full

            layered_chain_sql(aggregate, era, edges) || chain_sql(aggregate, era, edges)
          end

          # The matview bakes each ancestor's watermark in as a literal;
          # refreshing it incrementally or re-deriving the cut at query time
          # would leak post-cut ancestor writes into the head. Only rebuilding
          # the definition (mint, merge) may move the cut.
          def compile_head!(aggregate, era, label, edges, full: false)
            storage_name = aggregate.storage_name
            view = matview(storage_name, era, label)
            body = head_body_sql(aggregate, era, edges, full: full)
            @db.exec(<<~SQL)
              CREATE MATERIALIZED VIEW #{quote(view)} AS
              #{body}
            SQL
            @db.exec("CREATE INDEX IF NOT EXISTS #{quote("#{view}_reduce_idx")} ON #{quote(view)} (aggregate_id, ordinal DESC)")

            ensure_head_snapshot!(storage_name, era)
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
            # Reads the snapshot's own operation column rather than hardcoding
            # 'save', so a tombstone here outranks a stale ancestor save row
            # by ordinal instead of letting it resurrect a deleted record.
            @db.exec(<<~SQL)
              CREATE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(view)}
                  UNION ALL
                  SELECT ordinal, id AS aggregate_id, operation, state
                  FROM #{quote(head_snapshot(storage_name, era))}
                ) merged ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
          end

          # Walks `was:` chains backward from the current name, so each
          # ancestor era's rows can be found under the name of their time.
          # names[:storage][e - 1] is the storage name for era e (1-based).
          def names_by_era(aggregate, edges)
            current = Array.new(edges.size + 1)
            current[edges.size] = aggregate.name
            (edges.size - 1).downto(0) do |index|
              declared = edges[index][:translation].for_aggregate(current[index + 1])
              current[index] = declared&.was || current[index + 1]
            end
            storage = current.map { |name| Naming.snake(name) }
            { current: current, storage: storage }
          end

          # Cuts each ancestor era's rows at the watermark recorded when its
          # successor was minted, so later writes to the old world don't leak in.
          def ancestor_tail_sql(names, era)
            watermarks = eras.to_h { |held| [held[:ordinal], held[:watermark]] }
            selects = (1...era).map do |ancestor|
              cut = watermarks[ancestor + 1]
              "SELECT ordinal, era, aggregate, aggregate_id, operation, state FROM #{quoted_journal} " \
                "WHERE era = #{ancestor} AND aggregate = #{text_literal(names[:storage][ancestor - 1])}" \
                "#{" AND ordinal <= #{cut}" if cut}"
            end
            selects.join(" UNION ALL ")
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
        end
      end
    end
  end
end
