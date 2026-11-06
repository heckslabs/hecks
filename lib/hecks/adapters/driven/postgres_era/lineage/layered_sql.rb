require_relative "sql_templates"

module Hecks
  module Adapters
    class PostgresRevisions
      class Lineage
        # The shortcut that builds an era from the matview of the era before it, rather than from
        # the whole journal. A chain that cannot take it falls back to `ChainSql#chain_sql`.
        module LayeredSql
          include SqlTemplates

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
        end
      end
    end
  end
end
