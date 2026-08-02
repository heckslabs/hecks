module Hecksagain
  module Adapters
    class Postgres
      class Lineage
        module HeadCompiler
          # ── head compilation ───────────────────────────────────────────

          # Era 1: the head is simply the latest save per id.
          def ensure_first_head!(storage_name)
            return if view_exists?(head_view(storage_name))

            @db.exec(<<~SQL)
              CREATE OR REPLACE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state
                FROM #{quoted_journal}
                WHERE aggregate = #{text_literal(storage_name)}
                ORDER BY aggregate_id, ordinal DESC
              ) latest WHERE operation = 'save'
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

            <<~SQL
              WITH layered AS (
                SELECT DISTINCT ON (aggregate_id) ordinal, aggregate_id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(prior_view)}
                  UNION ALL
                  SELECT ordinal, aggregate_id, operation, state FROM #{quoted_journal}
                  WHERE era = #{era - 1} AND aggregate = #{text_literal(names[:storage][era - 2])}#{cut ? " AND ordinal <= #{cut}" : ''}
                ) layers ORDER BY aggregate_id, ordinal DESC
              )
              SELECT ordinal, aggregate_id, operation,
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
              "edge_#{index + 1} AS (SELECT ordinal, era, aggregate_id, operation, " \
                "CASE WHEN era <= #{index + 1} AND operation = 'save' THEN #{expression} ELSE state END AS state " \
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
          # CTEs, watermarks baked in), then overlay live current-era rows
          # in a plain view.
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

            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(storage_name))}")
            @db.exec(<<~SQL)
              CREATE VIEW #{quote(head_view(storage_name))} AS
              SELECT id, state FROM (
                SELECT DISTINCT ON (aggregate_id) aggregate_id AS id, operation, state FROM (
                  SELECT ordinal, aggregate_id, operation, state FROM #{quote(view)}
                  UNION ALL
                  SELECT ordinal, aggregate_id, operation, state FROM #{quoted_journal}
                  WHERE era = #{era.to_i} AND aggregate = #{text_literal(storage_name)}
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
            @db.exec_params(
              "SELECT 1 FROM information_schema.views WHERE table_name = $1 " \
              "UNION SELECT 1 FROM pg_matviews WHERE matviewname = $1",
              [name]
            ).ntuples.positive?
          end
        end
      end
    end
  end
end
