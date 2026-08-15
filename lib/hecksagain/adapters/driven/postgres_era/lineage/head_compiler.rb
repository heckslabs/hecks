require_relative "../../../../naming"

module Hecksagain
  module Adapters
    class PostgresEra
      class Lineage
        module HeadCompiler
          # ── head compilation ───────────────────────────────────────────

          # The snapshot table backing one aggregate's CURRENT era: one row
          # per live id, upserted transactionally by PostgresEra#append
          # alongside the journal insert it belongs to, never derived by
          # scanning history thereafter. Idempotent and unguarded by
          # `provisioner?` — a plain per-aggregate table, the same
          # privilege class as the per-aggregate views/matviews already
          # created this way, not the shared owner-only journal.
          #
          # BACKFILLED, not just created, the FIRST time this table comes
          # into existence for a domain that already has journal history —
          # a fresh era (compile_head! at mint) never has any, but era 1
          # against an EXISTING deployment (any domain running before this
          # snapshot table existed at all) does, and an empty table would
          # silently erase every already-written record from every read
          # the instant the head view starts pointing at it. Checked
          # BEFORE the CREATE, not via ON CONFLICT or similar — this only
          # ever needs to run once, at the exact moment the table is born.
          def ensure_head_snapshot!(storage_name, era)
            name = head_snapshot(storage_name, era)
            return if table_exists?(name)

            # Locked, not a bare CREATE TABLE IF NOT EXISTS — two processes
            # booting this aggregate for the very first time concurrently
            # must not race to CREATE (one wins, one gets a real Postgres
            # error) NOR both backfill (harmless but wasteful, a full
            # journal scan twice). Re-checked under the lock: the fast
            # path above skips locking entirely once any boot has already
            # finished this once, which is every boot after the first.
            #
            # NESTABLE — this runs both standalone (adapter boot, its own
            # transaction) and from `compile_head!` while `mint_era!` is
            # already mid-transaction (its manual `BEGIN`, held open for
            # the era row, every aggregate's matview, and the advisory
            # lock advance_era! relies on). `@db.transaction` is a bare
            # BEGIN/COMMIT with no savepoint nesting (see H2 in
            # docs/audits/2026-08-10-main-bug-audit.md) — called while
            # already inside a transaction, its COMMIT would end THAT
            # transaction early, releasing mint's advisory lock and
            # letting a later step run uncommitted. `nested_transaction`
            # tells the two cases apart and uses a SAVEPOINT for the
            # second, so the surrounding mint stays one real transaction
            # from BEGIN to its own COMMIT regardless of how deep this is
            # called from.
            nested_transaction("hecks_head_snapshot") do
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_head_snapshot:' || $1))", [name])
              next if table_exists?(name)

              @db.exec(<<~SQL)
                CREATE TABLE #{quote(name)} (
                  id      text PRIMARY KEY,
                  ordinal bigint NOT NULL,
                  state   jsonb NOT NULL
                )
              SQL
              backfill_head_snapshot!(name, storage_name, era)
            end
          end

          # The exact reduction era 1's OLD live view used to run on every
          # single read — DISTINCT ON latest-per-id, saves only — run
          # here, once, as an INSERT instead of a view body.
          def backfill_head_snapshot!(name, storage_name, era)
            @db.exec(<<~SQL)
              INSERT INTO #{quote(name)} (id, ordinal, state)
              SELECT id, ordinal, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, ordinal, operation, state
                FROM #{quoted_journal}
                WHERE era = #{era.to_i} AND aggregate = #{text_literal(storage_name)}
                ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
          end

          def table_exists?(name)
            @db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name]).getvalue(0, 0) == "t"
          end

          # A transaction wrapper safe to call from inside an already-open
          # transaction, unlike `PG::Connection#transaction` (bare
          # BEGIN/COMMIT, no savepoint nesting — see H2). Standalone
          # (`PQTRANS_IDLE`), this is `@db.transaction` itself: a real
          # transaction, committed or rolled back on the way out. Nested
          # (anything else — `PQTRANS_INTRANS` from a manual `BEGIN` like
          # mint_era!'s, or the gem's own `#transaction`), it's a SAVEPOINT
          # instead: released on success, rolled back to (then the error
          # re-raised) on failure, and either way the surrounding
          # transaction is never touched — no early COMMIT, no early
          # release of whatever advisory lock it holds.
          def nested_transaction(name)
            return @db.transaction { yield } if @db.transaction_status == PG::PQTRANS_IDLE

            @db.exec("SAVEPOINT #{name}")
            begin
              yield
              @db.exec("RELEASE SAVEPOINT #{name}")
            rescue StandardError
              @db.exec("ROLLBACK TO SAVEPOINT #{name}")
              raise
            end
          end

          # Era 1: the head is the snapshot table itself, verbatim — no
          # per-read reduction over history left to do, because `append`
          # already keeps the snapshot current as of every write.
          def ensure_first_head!(storage_name)
            ensure_head_snapshot!(storage_name, 1)
            @db.exec(<<~SQL)
              CREATE OR REPLACE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM #{quote(head_snapshot(storage_name, 1))}
            SQL
          end

          # The compiled chain over the ancestor tail — the matview's body,
          # also runnable as a LIVE query (the audit previews a pending
          # era through exactly this SQL before anything is minted).
          #
          # NEVER flatten the edges into one merged rule set, however
          # tempting the optimization looks. The two-line counterexample:
          # edge 1 renames A→B, edge 2 renames C→A. Flattened, a single
          # phase order either applies C→A before A→B (aliasing C's value
          # into B) or drops the recycled name entirely — there is NO
          # correct position for both rules in one pass. Chaining the
          # original edges in mint order reproduces the true execution
          # exactly and needs no such reasoning.
          # ONLY THE LATEST ANCESTOR ENTRY PER ID IS OBSERVABLE. The head,
          # the tail-merge, and the audit all reduce by
          # DISTINCT ON (aggregate_id) ORDER BY ordinal DESC before anyone
          # reads a state, so an entry with a newer sibling can never
          # reach a reader. Translating those siblings computes and stores
          # rows nothing can observe — on an append-only journal a record
          # edited a hundred times cost a hundred translations to serve
          # one.
          #
          # So the tail is reduced BEFORE the chain, not after. The
          # translated output is identical (the reducer is idempotent and
          # the survivor is the same row either way); only the work
          # changes, from |journal entries| to |distinct records|.
          #
          # `era` must survive the reduction: each edge's CASE reads it to
          # decide whether a row is old enough to need that edge applied.
          def latest_per_id(tail)
            return tail if tail.to_s.empty?

            "SELECT DISTINCT ON (aggregate_id) ordinal, era, aggregate, aggregate_id, operation, state " \
              "FROM (#{tail}) tail_entries ORDER BY aggregate_id, ordinal DESC"
          end

          # THE LAYERED BUILD — era N from era N-1's matview, not from raw
          # history. Returns nil when it cannot apply, and the caller
          # falls back to the full chain above.
          #
          # The algebra it rests on, both halves load-bearing:
          #
          #   1. THE CUTS DO NOT MOVE. ancestor_tail_sql cuts ancestor k at
          #      W(k+1) — the watermark recorded when era k+1 was minted.
          #      Those are the SAME literals in the era N-1 build and the
          #      era N build, so era N-1's matview already carries exactly
          #      the cut era N needs for eras 1..N-2. Only era N-1's own
          #      rows are new, and they are cut at W(N). The watermark is
          #      still a literal baked into a definition; it is simply
          #      baked into the layer beneath. (This is why the tail-merge
          #      must pass full: — it moves every watermark at once.)
          #
          #   2. REDUCING IS ASSOCIATIVE. reduce(A ∪ B) == reduce(reduce(A) ∪ B),
          #      because the survivor is max-ordinal-per-id either way. So
          #      reducing per layer is the same answer as reducing the
          #      whole tail once.
          #
          # And every row on both sides of the union is already in era
          # N-1's shape — the matview because it was chained through edge
          # N-2, era N-1's own rows because that is the shape they were
          # written under — so the final edge applies uniformly, with no
          # per-era CASE. That equality is asserted, not argued: the spec
          # builds a third era both ways and diffs them.
          def layered_chain_sql(aggregate, era, edges)
            return nil if era < 3 || edges.size < 2

            held = eras
            prior = held.find { |candidate| candidate[:ordinal] == era - 1 }
            return nil unless prior && prior[:label]

            prior_view = matview(aggregate.storage_name, era - 1, prior[:label])
            return nil unless view_exists?(prior_view)

            names = names_by_era(aggregate, edges)
            cut = held.find { |candidate| candidate[:ordinal] == era }&.dig(:watermark)
            declared = edges.last[:translation].for_aggregate(names[:current][edges.size])
            expression = declared ? compile_rules(declared) : "state"
            id_column = rekeyed?(declared) ? id_case("operation = 'save'", declared) : "aggregate_id"

            <<~SQL
              WITH layered AS (
                SELECT DISTINCT ON (aggregate_id) ordinal, aggregate_id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(prior_view)}
                  UNION ALL
                  SELECT ordinal, aggregate_id, operation, state FROM #{quoted_journal}
                  WHERE era = #{era - 1} AND aggregate = #{text_literal(names[:storage][era - 2])}#{cut ? " AND ordinal <= #{cut}" : ''}
                ) layers ORDER BY aggregate_id, ordinal DESC
              )
              SELECT ordinal, #{id_column}, operation,
                     CASE WHEN operation = 'save' THEN #{expression} ELSE state END AS state
              FROM layered
            SQL
          end

          def chain_sql(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = latest_per_id(ancestor_tail_sql(names, era))
            chain = edges.each_with_index.map do |edge, index|
              declared = edge[:translation].for_aggregate(names[:current][index + 1])
              expression = declared ? compile_rules(declared) : "state"
              guard = "era <= #{index + 1} AND operation = 'save'"
              id_column = rekeyed?(declared) ? id_case(guard, declared) : "aggregate_id"
              "edge_#{index + 1} AS (SELECT ordinal, era, #{id_column}, operation, " \
                "CASE WHEN #{guard} THEN #{expression} ELSE state END AS state " \
                "FROM #{index.zero? ? 'tail' : "edge_#{index}"})"
            end

            <<~SQL
              WITH tail AS (#{tail}),
              #{chain.join(",\n")}
              SELECT ordinal, aggregate_id, operation, state FROM edge_#{edges.size}
            SQL
          end

          # The translated tail as it would stand in era `era`, latest
          # entry per id, saves only — what the audit holds up against the
          # bluebook and the edge.
          def translated_latest(aggregate, era, edges)
            latest_of(chain_sql(aggregate, era, edges))
          end

          # The UNtranslated ancestor tail, latest entry per id — the
          # "before" side of every per-rule preservation check.
          def ancestor_latest(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = ancestor_tail_sql(names, era)
            return {} if tail.empty?

            latest_of("SELECT ordinal, era, aggregate_id, operation, state FROM (#{tail}) tail_rows")
          end

          def latest_of(sql)
            rows = @db.exec(<<~SQL)
              SELECT aggregate_id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state
                FROM (#{sql}) chained ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
            rows.to_h { |row| [row["aggregate_id"], JSON.parse(row["state"])] }
          end

          # Era N: materialize the translated ancestor tail (edge chain as
          # CTEs, watermarks baked in), then overlay this era's OWN live
          # rows — read from its snapshot table, not re-derived from raw
          # history — in a plain view.
          #
          # THE FROZEN-TAIL INVARIANT. This materialized view is correct
          # by construction only because BOTH of these hold:
          #   1. journal rows are never updated or deleted (immutability
          #      by privilege), and
          #   2. the watermark is baked into this definition as a LITERAL,
          #      so post-cut ancestor writes — which DO keep arriving
          #      while a fork is live — can never enter the head, even on
          #      a full REFRESH.
          # The ancestor partition is append-only but NOT frozen. Any
          # future "optimization" that refreshes incrementally, reads the
          # watermark from hecks_eras at query time, or otherwise
          # re-derives the cut will silently leak the old world's post-cut
          # writes into the new head. Rebuilding the definition (mint,
          # merge) is the only way the cut may move.
          # `full:` forces a rebuild from the raw journal. The tail-merge
          # needs it: it moves EVERY watermark to the new tip, so every
          # ancestor matview's cut goes stale in the same statement, and
          # layering on one would carry a cut that no longer exists.
          #
          # THE LIVE HALF used to be `WHERE era = era AND aggregate = name`
          # over the raw journal — a DISTINCT ON that re-reduced this era's
          # ENTIRE write history on every single read, the exact cost this
          # snapshot table exists to avoid (PostgresEra#append keeps it
          # current, transactionally, as of every write). The union below
          # is bounded by LIVE RECORD COUNT for this era instead of its
          # write count; the ancestor side was already bounded that way
          # (the matview only ever holds the reduced tail, never raw
          # history — see latest_per_id's own comment).
          def compile_head!(aggregate, era, label, edges, full: false)
            storage_name = aggregate.storage_name
            view = matview(storage_name, era, label)
            body =
              if !full && (layered = layered_chain_sql(aggregate, era, edges))
                layered
              else
                chain_sql(aggregate, era, edges)
              end
            @db.exec(<<~SQL)
              CREATE MATERIALIZED VIEW #{quote(view)} AS
              #{body}
            SQL

            # era-qualified, always a FRESH table for a newly-minted era —
            # no separate reset step needed; there is structurally nothing
            # in it yet for anyone to have written, until an append lands
            # under this era specifically.
            ensure_head_snapshot!(storage_name, era)
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
            @db.exec(<<~SQL)
              CREATE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(view)}
                  UNION ALL
                  SELECT ordinal, id AS aggregate_id, 'save' AS operation, state
                  FROM #{quote(head_snapshot(storage_name, era))}
                ) merged ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
          end

          # The aggregate's storage name AS OF each era: `was:` chains
          # walked backward from the current name, one edge at a time.
          # names[:current][i] is the declared (Pascal) name after edge i;
          # names[:storage][e] the snake storage name DURING era e (1-based).
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

          # Rows this aggregate contributed to every ancestor era, under
          # the name it had THEN, cut at the watermark recorded when the
          # next era was minted.
          def ancestor_tail_sql(names, era)
            watermarks = eras.to_h { |held| [held[:ordinal], held[:watermark]] }
            selects = (1...era).map do |ancestor|
              cut = watermarks[ancestor + 1]
              "SELECT ordinal, era, aggregate, aggregate_id, operation, state FROM #{quoted_journal} " \
                "WHERE era = #{ancestor} AND aggregate = #{text_literal(names[:storage][ancestor - 1])}" \
                "#{cut ? " AND ordinal <= #{cut}" : ''}"
            end
            selects.join(" UNION ALL ")
          end

          # One edge's rules over one jsonb state, compiled as a nested
          # expression tree — hecks_tr_* helpers composed innermost-first
          # in the reference transform's phase order (renames, moves,
          # converts, drops), computes last. `retype` compiles to nothing:
          # stored state never carries a type name.
          def compile_rules(declared)
            expression = "state"
            declared.renames.each do |old_name, new_name|
              expression = "hecks_tr_rename(#{expression}, #{text_literal(old_name)}, #{text_literal(new_name)})"
            end
            declared.moves.each do |move|
              expression = "hecks_tr_move(#{expression}, #{path_literal(move.from)}, #{path_literal(move.to)}, " \
                           "#{text_literal("move #{move.from} to: #{move.to}")})"
            end
            declared.converts.each do |convert|
              pairs = JSON.generate(convert.values.map { |key, value| [key, value] })
              expression = "hecks_tr_convert(#{expression}, #{path_literal(convert.from)}, #{path_literal(convert.to)}, " \
                           "#{text_literal(pairs)}::jsonb, #{text_literal(convert.from)}, " \
                           "#{text_literal("convert #{convert.from} to: #{convert.to}")})"
            end
            declared.drops.each do |name|
              expression = "hecks_tr_drop(#{expression}, #{path_literal(name)})"
            end
            declared.computes.each do |compute|
              expression = compile_compute(expression, compute)
            end
            expression
          end

          # Whether THIS edge's declared rules for this aggregate include a
          # rekey — checked directly off the raw IR object, the same way
          # every other rule kind is already read in `compile_rules`
          # (`declared.computes`, `declared.moves`, ...), not through the
          # `Ports::Persistence::Lineage` wrapper the app-level consumers
          # (coverage_check.rb, minter.rb, layer_two.rb) go through — this
          # file builds SQL straight off the IR either way.
          def rekeyed?(declared) = declared && !declared.rekeys.empty?

          # THE ONLY TWO PLACES `aggregate_id` NEEDS TO CHANGE — every
          # other reduction/select in this file (`latest_per_id`,
          # `ancestor_tail_sql`, `latest_of`, `compile_head!`'s own final
          # view, `ensure_first_head!`) reads FROM a chain that, once these
          # two produce the right column, is already correct — see this
          # feature's own design notes for why. Guarded so the generated
          # SQL for the overwhelming common case (no rekey declared, every
          # existing domain today) stays the bare `aggregate_id` passthrough
          # it always was — this CASE only appears in an edge that actually
          # declares one.
          def id_case(guard, declared)
            "CASE WHEN #{guard} THEN #{compile_id_expression(declared)} ELSE aggregate_id END AS aggregate_id"
          end

          # THE REKEY'S OWN SQL — reading `state` directly, not the
          # progressively-built `expression` chain `compile_compute` reads
          # from. A rekey doesn't consume or move any field the way a move
          # or compute does (see `TranslationRekey`'s own comment), so
          # there is no same-edge rename/move ordering it needs to see
          # first — it reads the record's stored fields exactly as they
          # already are, the same `__s` convention `compile_compute`
          # exposes.
          def compile_id_expression(declared)
            rekey = declared.rekeys.first
            "(SELECT (#{rekey.sql}) FROM (SELECT (state) AS __s) __outer)"
          end

          # A compute is the one rule whose SQL is its only implementation
          # — evaluated exclusively here, inside the compiled head, never
          # in-process. The old field is exposed under its own name (as
          # text, exactly as the author's expression expects to cast it).
          def compile_compute(expression, compute)
            from = compute.from.to_s
            to = compute.to.to_s
            "(SELECT CASE WHEN __s ? #{text_literal(from)} THEN " \
              "hecks_tr_insert(__s - #{text_literal(from)}, #{path_literal(to)}, to_jsonb((#{compute.sql})), " \
              "#{text_literal("compute #{from} to: #{to}")}) " \
              "ELSE __s END " \
              "FROM (SELECT (#{expression}) AS __s) __outer, " \
              "LATERAL (SELECT (__s ->> #{text_literal(from)}) AS #{quote(from)}) __fields)"
          end

          def view_exists?(name)
            # pg_class + pg_table_is_visible, not information_schema/
            # pg_matviews by bare name — same shared-instance reasoning
            # as provisioning.rb's own catalog lookups: this must resolve
            # the name the same way search_path would, or a sibling
            # domain's same-named view satisfies a check meant for this
            # domain's own.
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
