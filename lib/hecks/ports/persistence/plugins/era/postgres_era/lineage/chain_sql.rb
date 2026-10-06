require_relative "../../../../../../naming"
require_relative "../../translation/rule_compiler"
require_relative "sql_templates"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The SQL that derives an era's head from the journal: each ancestor era's rows, cut at
        # the watermark recorded when its successor was minted, then every edge's rules chained
        # over them in mint order.
        module ChainSql
          include SqlTemplates

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
          def layered_chain_sql(aggregate, era, edges)
            return nil unless layerable?(era, edges)

            held = eras
            prior_view = existing_prior_view(aggregate, era, held)
            return nil unless prior_view

            layered_sql(aggregate, era, edges, held, prior_view)
          end

          # Chains the original edges in mint order rather than flattening them
          # into one rule set: edge 1 renaming A→B then edge 2 renaming C→A
          # has no single phase order that applies both correctly.
          def chain_sql(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            tail = latest_per_id(ancestor_tail_sql(names, era))
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
          def head_body_sql(aggregate, era, edges, full: false)
            return chain_sql(aggregate, era, edges) if full

            layered_chain_sql(aggregate, era, edges) || chain_sql(aggregate, era, edges)
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

          def layerable?(era, edges) = era >= 3 && edges.size >= 2 && edges.size == era - 1

          # The previous era's matview, when it is labelled and already built.
          def existing_prior_view(aggregate, era, held)
            prior = held.find { |candidate| candidate[:ordinal] == era - 1 }
            return nil unless prior && prior[:label]

            view = matview(aggregate.storage_name, era - 1, prior[:label])
            view if view_exists?(view)
          end

          def layered_sql(aggregate, era, edges, held, prior_view)
            names = names_by_era(aggregate, edges)
            declared = edges.last[:translation].for_aggregate(names[:current][edges.size])
            tokens = layered_tokens(prior_view, names, era, declared)
            format(LAYERED_SQL, tokens.merge(cut: cut_clause(held, era)))
          end

          def layered_tokens(prior_view, names, era, declared)
            { prior_view: quote(prior_view), journal: quoted_journal, prior_era: era - 1,
              aggregate: text_literal(names[:storage][era - 2]),
              id_column: id_column_for(declared, "operation = 'save'"), expression: rules_expression(declared) }
          end

          # Cuts the previous era's rows at the watermark recorded when this era was minted.
          def cut_clause(held, era)
            cut = held.find { |candidate| candidate[:ordinal] == era }&.dig(:watermark)
            " AND ordinal <= #{cut}" if cut
          end

          # One link of the chain: its edge's rules over the previous link.
          def edge_step_sql(edge, index, names)
            declared = edge[:translation].for_aggregate(names[:current][index + 1])
            guard = "era <= #{index + 1} AND operation = 'save'"
            "edge_#{index + 1} AS (SELECT ordinal, era, #{id_column_for(declared, guard)}, operation, " \
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
