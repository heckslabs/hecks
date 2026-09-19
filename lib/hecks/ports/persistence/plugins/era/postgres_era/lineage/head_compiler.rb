require_relative "../../../../../../naming"
require_relative "../../translation/rule_compiler"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The read side of lineage: builds and maintains, per aggregate per
        # era, the head-snapshot table (`ensure_head_snapshot!`/
        # `backfill_head_snapshot!`) and the compiled materialized
        # view/plain view (`compile_head!`) that translate and reduce the
        # append-only journal into the single current-era head a query
        # actually reads.
        module HeadCompiler
          # ── head compilation ───────────────────────────────────────────

          # Creates one aggregate's head-snapshot table for an era if it is missing,
          # brings an older table up to the current column shape, and backfills it
          # from the journal until the backfill is recorded complete.
          #
          # The snapshot table backing one aggregate's current era: one row
          # per live id, upserted transactionally by PostgresEra#append
          # alongside the journal insert it belongs to, never derived by
          # scanning history thereafter. Idempotent and unguarded by
          # `provisioner?` — a plain per-aggregate table, the same
          # privilege class as the per-aggregate views/matviews already
          # created this way, not the shared owner-only journal.
          #
          # Backfilled, not just created, the first time this table comes
          # into existence for a domain that already has journal history —
          # a fresh era (compile_head! at mint) never has any, but era 1
          # against an existing deployment (any domain running before this
          # snapshot table existed at all) does, and an empty table would
          # silently erase every already-written record from every read
          # the instant the head view starts pointing at it.
          #
          # Creation and backfill are deliberately two separate steps,
          # not one nested transaction — principle 1 (docs/implemented/postgres-era-
          # adapter-split-plan.md): no operation may hold a lock across a
          # scan whose duration scales with table size, and
          # `backfill_head_snapshot!` below is a chunked, resumable
          # scan (see `ResumableBackfill`), the opposite of something that
          # belongs inside one transaction. Creation alone (an empty
          # table, nothing to scan) still needs its short-held lock.
          # Backfill runs unconditionally after —
          # cheap and correct whether the table was just created, already
          # fully backfilled by a prior boot (one indexed point lookup via
          # `hecks_backfill_progress`, see ResumableBackfill), or left
          # mid-backfill by a crashed or still-racing concurrent boot
          # (picks up exactly where the last committed chunk left off).
          #
          # @param storage_name [String] the aggregate's snake-cased storage name in `era`
          # @param era [Integer] ordinal of the era the snapshot belongs to
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the DDL, a journal read, or an upsert
          def ensure_head_snapshot!(storage_name, era)
            name = head_snapshot(storage_name, era)
            unless table_exists?(name)
              # Locked, not a bare CREATE TABLE IF NOT EXISTS — two
              # processes booting this aggregate for the very first time
              # concurrently must not race to `CREATE` (one wins, one gets a
              # real Postgres error). Re-checked under the lock: the fast
              # path above skips locking entirely once any boot has
              # already finished this once, which is every boot after the
              # first.
              #
              # Nestable — this runs both standalone (adapter boot, its
              # own transaction) and from `compile_head!` while
              # `mint_era!` is already mid-transaction (its manual
              # `BEGIN`, held open for the era row, every aggregate's
              # matview, and the advisory lock advance_era! relies on).
              # `@db.transaction` is a bare BEGIN/COMMIT with no savepoint
              # nesting (see H2 in docs/audits/2026-08-10-main-bug-
              # audit.md) — called while already inside a transaction, its
              # COMMIT would end that transaction early, releasing mint's
              # advisory lock and letting a later step run uncommitted.
              # `nested_transaction` tells the two cases apart and uses a
              # SAVEPOINT for the second, so the surrounding mint stays
              # one real transaction from BEGIN to its own COMMIT
              # regardless of how deep this is called from.
              nested_transaction("hecks_head_snapshot") do
                @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_head_snapshot:' || $1))", [name])
                next if table_exists?(name)

                # `operation` + a nullable `state` — H3, docs/audits/2026-08-
                # 10-main-bug-audit.md: a delete that just ran `DELETE FROM`
                # this table would leave no row at all for an id carried in
                # from an ancestor era. `compile_head!`'s union below would
                # then have nothing current-era to outrank the ancestor
                # matview's own (still-live-looking) `save` row with, so a
                # deleted ancestor-carried record would keep winning
                # `DISTINCT ON` forever. A delete upserts a tombstone row here
                # instead (`operation = 'delete'`, `state` NULL) — the
                # exact same ordinal-guarded upsert every write already
                # uses, so it participates in the union/`DISTINCT ON`
                # exactly like a save does, and out-ranks the ancestor row
                # by ordinal the same way a real re-save does
                # ("re-saves are masked correctly" — the audit's own
                # phrasing for why that half of the read path holds).
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
            # Self-healing for a table this ADR predates — same idiom as
            # `postgres/schema_builder.rb`'s own `hecks_version` backfill:
            # unconditional, runs on every boot, a no-op once the column
            # is there. A table created before H3's fix has no
            # `operation` column and a `state NOT NULL` constraint a
            # tombstone's NULL state would violate; both are corrected
            # here regardless of which branch above just ran.
            @db.exec("ALTER TABLE #{quote(name)} ADD COLUMN IF NOT EXISTS operation text NOT NULL DEFAULT 'save'")
            @db.exec("ALTER TABLE #{quote(name)} ALTER COLUMN state DROP NOT NULL")
            backfill_head_snapshot!(name, storage_name, era)
          end

          # Fills a head-snapshot table with the latest saved state of every live id
          # in one era's journal, one committed chunk at a time, resuming from the
          # cursor in `hecks_backfill_progress` and doing nothing once complete.
          #
          # The reduction a live view over the raw journal would run on every
          # single read — DISTINCT ON latest-per-id, saves only — run once,
          # chunked through `ResumableBackfill#chunked_backfill!` instead
          # of one blocking `INSERT ... SELECT` over the whole journal:
          # each chunk reads the next page of distinct ids (a plain SELECT,
          # no lock held — an ordinary reader or writer is never blocked
          # by this running), then upserts it under the same short-held
          # advisory lock + ordinal guard every other upsert in this
          # adapter already uses. See `ResumableBackfill`'s own header for
          # why this is resumable, not merely safe-to-restart.
          #
          # @param name [String] unquoted snapshot table name, from `head_snapshot`
          # @param storage_name [String] the aggregate's snake-cased storage name in `era`
          # @param era [Integer] ordinal of the era whose journal rows are read
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a journal read or an upsert
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
                  # Always `'save'` — `source_sql` above already filtered
                  # to `operation = 'save'`, so nothing this backfill ever
                  # sees is a delete tombstone.
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

          # Tells whether a relation of this name resolves on the connection's search
          # path, by `to_regclass` — any relation kind counts, not only a table.
          #
          # @param name [String] unquoted relation name
          # @return [Boolean] true when `to_regclass` resolves the name
          # @raise [PG::Error] if the lookup fails
          def table_exists?(name)
            @db.exec_params("SELECT to_regclass($1) IS NOT NULL AS present", [name]).getvalue(0, 0) == "t"
          end

          # Runs the block atomically: in its own transaction when the connection is
          # idle, under a savepoint when a transaction is already open.
          #
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
          #
          # @param name [String] savepoint name for the nested case, interpolated
          #   unquoted so it must be a plain SQL identifier; unused when standalone
          # @yield the statements to run atomically
          # @yieldparam connection [PG::Connection] the connection, standalone only;
          #   the nested case yields nothing
          # @return [Object] the block's value when standalone, the `PG::Result` of
          #   `RELEASE SAVEPOINT` when nested; callers here ignore it
          # @raise [StandardError] whatever the block raises, re-raised after the
          #   transaction or the savepoint is rolled back
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

          # Ensures era 1's snapshot table for an aggregate, then points its head
          # view at that table's saved rows, replacing any earlier definition.
          #
          # Era 1: the head is the snapshot table itself, verbatim — no
          # per-read reduction over history left to do, because `append`
          # already keeps the snapshot current as of every write.
          #
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the DDL or the snapshot backfill
          def ensure_first_head!(storage_name)
            ensure_head_snapshot!(storage_name, 1)
            # `WHERE operation = 'save'` — era 1 has no ancestor tail to
            # worry about, but the snapshot table can hold delete
            # tombstones too (H3, see `ensure_head_snapshot!`'s own
            # comment), and a tombstone's `state` is NULL: without this
            # filter a deleted id would still resolve here, just to a nil
            # state, instead of correctly falling out of the head at all.
            @db.exec(<<~SQL)
              CREATE OR REPLACE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM #{quote(head_snapshot(storage_name, 1))} WHERE operation = 'save'
            SQL
          end

          # Wraps an ancestor-tail query so it keeps only the newest journal entry
          # per aggregate id, deletes included, before any edge is applied.
          #
          # Only the latest ancestor entry per ID is observable. The head,
          # the tail-merge, and the audit all reduce by
          # DISTINCT ON (aggregate_id) ORDER BY ordinal DESC before anyone
          # reads a state, so an entry with a newer sibling can never
          # reach a reader. Translating those siblings computes and stores
          # rows nothing can observe — on an append-only journal a record
          # edited a hundred times cost a hundred translations to serve
          # one.
          #
          # So the tail is reduced before the chain, not after. The
          # translated output is identical (the reducer is idempotent and
          # the survivor is the same row either way); only the work
          # changes, from |journal entries| to |distinct records|.
          #
          # `era` must survive the reduction: each edge's `CASE` reads it to
          # decide whether a row is old enough to need that edge applied.
          #
          # @param tail [String, nil] the `ancestor_tail_sql` SELECT, or an empty string
          #   (or nil) when the aggregate has no ancestor era
          # @return [String, nil] a `SELECT DISTINCT ON (aggregate_id)` over `tail`, or
          #   `tail` itself, unchanged, when it is empty or nil
          def latest_per_id(tail)
            return tail if tail.to_s.empty?

            "SELECT DISTINCT ON (aggregate_id) ordinal, era, aggregate, aggregate_id, operation, state " \
              "FROM (#{tail}) tail_entries ORDER BY aggregate_id, ordinal DESC"
          end

          # Builds the ancestor-tail SQL for era N by applying only the last edge to
          # era N-1's existing matview plus era N-1's own journal rows.
          #
          # **The layered build** — era N from era N-1's matview, not from raw
          # history. Returns nil when it cannot apply, and the caller
          # falls back to the full chain (`chain_sql`).
          #
          # The algebra it rests on, both halves load-bearing:
          #
          #   1. The cuts do not move. ancestor_tail_sql cuts ancestor k at
          #      W(k+1) — the watermark recorded when era k+1 was minted.
          #      Those are the same literals in the era N-1 build and the
          #      era N build, so era N-1's matview already carries exactly
          #      the cut era N needs for eras 1..N-2. Only era N-1's own
          #      rows are new, and they are cut at W(N). The watermark is
          #      still a literal baked into a definition; it is simply
          #      baked into the layer beneath. (This is why the tail-merge
          #      must pass full: — it moves every watermark at once.)
          #
          #   2. Reducing is associative. reduce(A ∪ B) == reduce(reduce(A) ∪ B),
          #      because the survivor is max-ordinal-per-id either way. So
          #      reducing per layer is the same answer as reducing the
          #      whole tail once.
          #
          # And every row on both sides of the union is already in era
          # N-1's shape — the matview because it was chained through edge
          # N-2, era N-1's own rows because that is the shape they were
          # written under — so the final edge applies uniformly, with no
          # per-era `CASE`. That equality is asserted, not argued: the spec
          # builds a third era both ways and diffs them.
          #
          # `edges.size != era - 1` is a guard in its own right, not a
          # restatement of the two before it: `names_by_era(aggregate,
          # edges)` sizes `names[:storage]` to `edges.size + 1`, and the
          # union in the body indexes it at `names[:storage][era - 2]` — correct
          # only when `edges` is the full chain reaching `era` (mint's own
          # call, and the audit's own "after" reading, both are). A caller
          # handed a shorter chain against the same `era` — exactly what
          # the audit's own "before" reading is, `chain[0..-2]` against the
          # unchanged target era — would index `names[:storage]` out of
          # its real bounds instead of falling back to `chain_sql` the way
          # every other mismatch here already does. Guarded structurally,
          # not by trusting every future caller to know this invariant.
          #
          # The guard clauses are the method: each rules out one way
          # the layered shortcut cannot honestly apply (era too young, too
          # few edges, a mismatched chain length, no prior era, no label,
          # no materialized prior view) before the SQL-building tail runs.
          # Splitting them out would separate each guard from the algebra
          # comment it protects, and thread `held`/`prior`/`prior_view`
          # back out as return values with no simpler shape than they
          # already have.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as the target era declares it
          # @param era [Integer] ordinal of the era being built
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order; only the last is applied
          # @return [String, nil] the layered SELECT, or nil when `era` is under 3, `edges`
          #   is not the full chain of `era - 1` edges, or era N-1 has no row, no label, or
          #   no existing matview
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          # @raise [PG::Error] if reading `hecks_eras` or the catalog fails
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

          # Builds the full translation query for an aggregate: the reduced ancestor
          # tail as a CTE, then one CTE per edge in mint order, edge k applying its
          # rules only to saved rows written in era k or earlier.
          #
          # The compiled chain over the ancestor tail — the matview's body,
          # also runnable as a live query (the audit previews a pending
          # era through exactly this SQL before anything is minted).
          #
          # Never flatten the edges into one merged rule set, however
          # tempting the optimization looks. The two-line counterexample:
          # edge 1 renames A→B, edge 2 renames C→A. Flattened, a single
          # phase order either applies C→A before A→B (aliasing C's value
          # into B) or drops the recycled name entirely — there is no
          # correct position for both rules in one pass. Chaining the
          # original edges in mint order reproduces the true execution
          # exactly and needs no such reasoning.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as the target era declares it
          # @param era [Integer] ordinal of the era being built; ancestors are eras
          #   `1...era`
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order
          # @return [String] a `WITH tail AS (...), edge_1 AS (...), ...` SELECT yielding
          #   `ordinal, aggregate_id, operation, state`
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          # @raise [PG::Error] if reading `hecks_eras` fails
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
                "FROM #{index.zero? ? 'tail' : "edge_#{index}"})"
            end

            <<~SQL
              WITH tail AS (#{tail}),
              #{chain.join(",\n")}
              SELECT ordinal, aggregate_id, operation, state FROM edge_#{edges.size}
            SQL
          end

          # Runs the head body as a live query and returns every surviving record's
          # translated state, without creating or changing any relation.
          #
          # The translated tail as it would stand in era `era`, latest
          # entry per id, saves only — what the audit holds up against the
          # bluebook and the edge. Reads through `head_body_sql`, the same
          # layered-or-full choice `compile_head!` makes at real mint time
          # (that method's own comment has the full reasoning) — so this
          # is provably what the real mint will materialize, not a second
          # implementation that could silently drift from it. Safe for
          # both real callers: the "after" reading (`edges` is the full
          # chain reaching `era`) and the "before" reading (`edges` one
          # shorter, same `era` — `audit.rb`'s own `samples_for`/`check`
          # callers) — `layered_chain_sql`'s own `edges.size != era - 1`
          # guard falls back to `chain_sql` exactly when the shorter
          # chain can't honestly answer the layered question.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as the target era declares it
          # @param era [Integer] ordinal of the era being previewed
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order; the full chain, or one shorter
          # @return [Hash{String => Hash}] parsed state keyed by aggregate id, for every
          #   id whose latest entry is a save; `{}` when nothing survives
          # @raise [PG::Error] if the preview query fails, such as a convert rule
          #   meeting a value it does not map
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          def translated_latest(aggregate, era, edges)
            latest_of(head_body_sql(aggregate, era, edges))
          end

          # Reads the ancestor tail with no edge applied and returns each surviving
          # record's state exactly as its own era stored it.
          #
          # The untranslated ancestor tail, latest entry per id — the
          # "before" side of every per-rule preservation check.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as the target era declares it
          # @param era [Integer] ordinal of the target era; ancestors are eras `1...era`
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] the edge chain,
          #   read only for the `was:` names the aggregate carried in each ancestor era
          # @return [Hash{String => Hash}] parsed state keyed by aggregate id, for every
          #   id whose latest entry is a save; `{}` when there is no ancestor era
          # @raise [PG::Error] if the query fails
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          def ancestor_latest(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = ancestor_tail_sql(names, era)
            return {} if tail.empty?

            latest_of("SELECT ordinal, era, aggregate_id, operation, state FROM (#{tail}) tail_rows")
          end

          # Runs a journal-shaped query and reduces it the way the head does: newest
          # entry per aggregate id by ordinal, dropping any id whose newest entry is
          # a delete.
          #
          # @param sql [String] a SELECT yielding at least `ordinal`, `aggregate_id`,
          #   `operation` and `state`
          # @return [Hash{String => Hash}] `JSON.parse`d state keyed by aggregate id;
          #   `{}` when no id survives
          # @raise [PG::Error] if the query fails
          def latest_of(sql)
            rows = @db.exec(<<~SQL)
              SELECT aggregate_id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id, operation, state
                FROM (#{sql}) chained ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
            SQL
            rows.to_h { |row| [row["aggregate_id"], JSON.parse(row["state"])] }
          end

          # Chooses the SQL a head's ancestor matview is built from: the layered
          # build when it applies and `full` is off, otherwise the full chain.
          #
          # The one place that picks layered vs full — its own method so the
          # audit's own preview (`translated_latest`, above: both
          # `bin/translation_audit`'s standalone run and the real
          # mint-time gate in coverage_check.rb#audit!) reads through the
          # identical branch selection a real mint's own `compile_head!`
          # will use, rather than a second, hand-kept-in-sync copy of this
          # same "layered when eligible, else full" choice. A preview that
          # called `chain_sql` unconditionally would let the real mint
          # (`compile_head!`, `full: false` by default), for any era >= 3,
          # materialize via the layered path while the
          # preview that approved it never exercised that branch at all.
          # `full:` mirrors `compile_head!`'s own default; tail_merge's
          # `full: true` rebuild is the one caller that ever needs the
          # non-layered branch unconditionally.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as the target era declares it
          # @param era [Integer] ordinal of the era being built
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order
          # @param full [Boolean] true skips the layered build and always chains from
          #   the raw journal
          # @return [String] a SELECT yielding `ordinal, aggregate_id, operation, state`
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          # @raise [PG::Error] if reading `hecks_eras` or the catalog fails
          def head_body_sql(aggregate, era, edges, full: false)
            return chain_sql(aggregate, era, edges) if full

            layered_chain_sql(aggregate, era, edges) || chain_sql(aggregate, era, edges)
          end

          # Builds one aggregate's head for a minted era: the ancestor matview, its
          # reduce index, the era's snapshot table, and a head view recreated over
          # the two. Runs inside the caller's mint or merge transaction.
          #
          # Era N: materialize the translated ancestor tail (edge chain as
          # CTEs, watermarks baked in), then overlay this era's own live
          # rows — read from its snapshot table, not re-derived from raw
          # history — in a plain view.
          #
          # **The frozen-tail invariant**. This materialized view is correct
          # by construction only because both of these hold:
          #   1. journal rows are never updated or deleted (immutability
          #      by privilege), and
          #   2. the watermark is baked into this definition as a literal,
          #      so post-cut ancestor writes — which do keep arriving
          #      while a fork is live — can never enter the head, even on
          #      a full `REFRESH`.
          # The ancestor partition is append-only but not frozen. Any
          # future "optimization" that refreshes incrementally, reads the
          # watermark from hecks_eras at query time, or otherwise
          # re-derives the cut will silently leak the old world's post-cut
          # writes into the new head. Rebuilding the definition (mint,
          # merge) is the only way the cut may move.
          #
          # `full:` forces a rebuild from the raw journal. The tail-merge
          # needs it: it moves every watermark to the new tip, so every
          # ancestor matview's cut goes stale in the same statement, and
          # layering on one would carry a cut that no longer exists.
          #
          # The live half reads the snapshot table, not `WHERE era = era AND
          # aggregate = name` over the raw journal — that would be a
          # DISTINCT ON re-reducing this era's
          # entire write history on every single read, the exact cost the
          # snapshot table exists to avoid (PostgresEra#append keeps it
          # current, transactionally, as of every write). The head view's union
          # is bounded by live record count for this era instead of its
          # write count; the ancestor side is bounded the same way
          # (the matview only ever holds the reduced tail, never raw
          # history — see latest_per_id's own comment).
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate as era `era` declares it
          # @param era [Integer] ordinal of the era whose head is built, 2 or later
          # @param label [String] the era's minted label, part of the matview's name
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order, reaching `era`
          # @param full [Boolean] true builds the matview from the raw journal rather
          #   than layering on era N-1's matview; the tail-merge passes it
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a statement, including a matview of
          #   that name already existing or a convert rule meeting an unmapped value
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          def compile_head!(aggregate, era, label, edges, full: false)
            storage_name = aggregate.storage_name
            view = matview(storage_name, era, label)
            body = head_body_sql(aggregate, era, edges, full: full)
            @db.exec(<<~SQL)
              CREATE MATERIALIZED VIEW #{quote(view)} AS
              #{body}
            SQL
            # Additive, changes nothing about what can be pushed through
            # the reduction (that wall is structural, an index doesn't
            # move it — see this file's own module header) — only speeds
            # up the reduction itself, which every read still has to run
            # regardless of a field cache's own two-phase shortcut (a
            # multi-clause query with an uncached clause, an order_by-only
            # query, or simply every read before Track C's cache tables
            # exist for a given field all still hit this). Worth having
            # on any supported server; genuinely skip-scan-usable once
            # running on PG18+.
            @db.exec("CREATE INDEX IF NOT EXISTS #{quote("#{view}_reduce_idx")} ON #{quote(view)} (aggregate_id, ordinal DESC)")

            # era-qualified, always a fresh table for a newly-minted era —
            # no separate reset step needed; there is structurally nothing
            # in it yet for anyone to have written, until an append lands
            # under this era specifically.
            ensure_head_snapshot!(storage_name, era)
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
            # The current-era side reads its own `operation` column —
            # H3 (docs/audits/2026-08-10-main-bug-audit.md) — rather than
            # hardcoding `'save' AS operation` on the reasoning that a
            # delete simply removes its row from the snapshot table. For
            # an id carried in from an ancestor era, a removed row leaves the
            # ancestor matview's own `save` row as the only row on either
            # side of this union — which then wins `DISTINCT ON` and
            # `WHERE operation = 'save'` lets it straight through, so a
            # deleted ancestor-carried record keeps resurrecting forever.
            # The snapshot side upserts a real tombstone row on
            # delete (`ensure_head_snapshot!`'s own comment) instead of
            # deleting the row, so reading its actual `operation` here
            # lets that tombstone outrank the stale ancestor `save` row
            # by ordinal, exactly the way a genuine re-save does.
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

          # Resolves the name an aggregate carried in every era of the chain, so each
          # ancestor era's journal rows can be found under the name of their time.
          #
          # The aggregate's storage name as of each era: `was:` chains
          # walked backward from the current name, one edge at a time.
          # names[:current][i] is the declared (Pascal) name after edge i;
          # names[:storage][i] its snake-cased storage name, so era e
          # (1-based) is `names[:storage][e - 1]`.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate under its current name
          # @param edges [Array<Hash{Symbol => Bluebook::Translation}>] one
          #   `{ translation: }` per edge, in mint order
          # @return [Hash{Symbol => Array<String>}] `:current` and `:storage`, each of
          #   `edges.size + 1` names, index 0 being era 1
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

          # Builds the `UNION ALL` of one journal SELECT per ancestor era, the raw
          # input every translation chain starts from.
          #
          # Rows this aggregate contributed to every ancestor era, under
          # the name it had then, cut at the watermark recorded when the
          # next era was minted.
          #
          # @param names [Hash{Symbol => Array<String>}] the `names_by_era` result; only
          #   `:storage` is read
          # @param era [Integer] ordinal of the target era; ancestors are eras `1...era`
          # @return [String] the unioned SELECT, or `""` when `era` is 1; an ancestor
          #   whose successor has no recorded watermark is read uncut
          # @raise [Runtime::WiringError] if a held era's text fails its digest check
          # @raise [PG::Error] if reading `hecks_eras` fails
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

          # compile_rules/rekeyed?/id_case/compile_id_expression/
          # compile_compute live in Translation::RuleCompiler — the
          # pure half of this compiler, with no database connection, no
          # watermark, no era chain. Separate so Exporter's build-time
          # SQL export (feeding rust/host's own boot-time mint) can call
          # the exact same code this file's own callers do, rather than
          # a hand-ported duplicate. See that module's own header.

          # Tells whether a view or materialized view of this name is visible on the
          # connection's search path; a table of the same name does not count.
          #
          # @param name [String] unquoted relation name
          # @return [Boolean] true when a visible `pg_class` row of kind `v` or `m` has
          #   that name
          # @raise [PG::Error] if the catalog lookup fails
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
