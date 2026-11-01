require_relative "../../../../naming"
require_relative "../../../../ports/persistence/plugins/era/translation/rule_compiler"
require_relative "sql_templates"
require_relative "split_sql"
require_relative "layered_sql"
require_relative "direct_sql"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The SQL that derives an era's head from the journal: each ancestor era's rows, cut at
        # the watermark recorded when its successor was minted, then every edge's rules chained
        # over them in mint order.
        module ChainSql
          include SqlTemplates
          include SplitSql
          include LayeredSql
          include DirectSql

          # Reduces the tail before chaining edges over it, not after: every
          # reader already reduces to latest-per-id, so translating a
          # superseded entry would be wasted work. `era` survives the
          # reduction because each edge's case still needs it.
          def latest_per_id(tail)
            return tail if tail.to_s.empty?

            "SELECT DISTINCT ON (aggregate_id) ordinal, era, aggregate, aggregate_id, operation, state " \
              "FROM (#{tail}) tail_entries ORDER BY aggregate_id, ordinal DESC"
          end

          # Chains the original edges in mint order rather than flattening them
          # into one rule set: edge 1 renaming A→B then edge 2 renaming C→A
          # has no single phase order that applies both correctly.
          def chain_sql(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = latest_per_id(target_tail_sql(names, era, edges))
            chain = edges.each_with_index.map { |edge, index| edge_step_sql(edge, index, names) }
            format(CHAIN_SQL, tail: tail, chain: chain.join(",\n"), last: edges.size)
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

          # The aggregate's head as the chain's last edge receives it: every edge but the last,
          # read under the name the held era gives the aggregate. The last edge's `was` is that
          # name, so a renamed aggregate's held rows are found, as `ancestor_latest` finds them.
          # Needs at least two edges; with one, `ancestor_latest` is the whole answer.
          def received_latest(aggregate, era, edges)
            held_name = edges.last[:translation].for_aggregate(aggregate.name)&.was || aggregate.name
            latest_of(chain_sql(Struct.new(:name).new(held_name), era, edges[0..-2]))
          end

          # Reduces to newest entry per aggregate id, dropping any id whose
          # newest entry is a delete rather than returning it with a nil state.
          def latest_of(sql)
            rows = @db.exec(format(LATEST_SQL, sql: sql))
            rows.to_h { |row| [row["aggregate_id"], JSON.parse(row["state"])] }
          end

          # The one place that picks layered vs full, so a preview
          # (translated_latest) can never approve a branch the real mint
          # doesn't take. `full:` mirrors compile_head!'s own default;
          # tail_merge is the one caller that forces it true.
          def head_body_sql(aggregate, era, edges, full: false, direct: direct_translation?(edges))
            return walked_sql(aggregate, era, edges, direct) if full

            layered_chain_sql(aggregate, era, edges) || walked_sql(aggregate, era, edges, direct)
          end

          # The whole chain from the journal: one composed step when `direct` and the chain composes,
          # otherwise one link per era.
          def walked_sql(aggregate, era, edges, direct)
            (direct && direct_chain_sql(aggregate, era, edges)) || chain_sql(aggregate, era, edges)
          end

          # Walks `was:` chains backward from the current name, so each
          # ancestor era's rows can be found under the name of their time.
          # names[:storage][e - 1] is the storage name for era e (1-based).
          def names_by_era(aggregate, edges)
            current = Array.new(edges.size + 1)
            current[edges.size] = aggregate.name
            (edges.size - 1).downto(0) { |index| current[index] = name_before(edges, current, index) }
            { current: current, storage: current.map { |name| Naming.snake(name) } }
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

          private

          # A split target's tail is its own journal rows plus the rows its split fans out of the
          # source.
          def target_tail_sql(names, era, edges)
            [ancestor_tail_sql(names, era), split_tail_sql(names, edges)].compact.reject(&:empty?).join(" UNION ALL ")
          end

          # One link of the chain: its edge's rules over the previous link. A link is `MATERIALIZED`
          # because its `CASE` names `state` twice: left to Postgres to inline, each link doubles
          # the
          # expression of the one before, and a chain of eighteen links overflows the 65,535
          # range-table entries one statement may hold.
          def edge_step_sql(edge, index, names)
            declared = edge[:translation].for_aggregate(names[:current][index + 1])
            guard = "era <= #{index + 1} AND operation = 'save'"
            "edge_#{index + 1} AS MATERIALIZED (SELECT ordinal, era, #{id_column_for(declared, guard)}, operation, " \
              "CASE WHEN #{guard} THEN #{rules_expression(declared)} ELSE state END AS state " \
              "FROM #{index.zero? ? "tail" : "edge_#{index}"})"
          end

          def rules_expression(declared)
            declared ? Translation::RuleCompiler.compile_rules(declared) : "state"
          end

          def id_column_for(declared, guard)
            return "aggregate_id" unless Translation::RuleCompiler.rekeyed?(declared)

            Translation::RuleCompiler.id_case(guard, declared)
          end

          def name_before(edges, current, index)
            declared = edges[index][:translation].for_aggregate(current[index + 1])
            declared&.was || current[index + 1]
          end
        end
      end
    end
  end
end
