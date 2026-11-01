require_relative "../../../../ports/persistence/plugins/era/translation/compose"
require_relative "sql_templates"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The head read in one step. Each held era's rows take the translation composed from that
        # era's edge to the last, instead of one link per later era. A chain that does not compose
        # exactly (two steps ruling one aggregate, a rekey or a split) has no direct form and
        # reads through `ChainSql#chain_sql` instead.
        module DirectSql
          include SqlTemplates

          # The bluebooks whose composed translations the direct translation spec proves
          # row-for-row equal to their chains.
          VERIFIED = %w[Hecks Bluebook Tickets QualityControl Composer Pizzas].freeze

          # Overrides the default of reading directly where the chain is verified.
          #
          # @return [Boolean, nil] true or false to force a path; nil to follow `VERIFIED`
          attr_writer :direct_translation

          # @param edges [Array<Hash>] the chain, one `{ translation: edge }` per era
          # @return [Boolean] whether the head should read through the composed step
          def direct_translation?(edges)
            return @direct_translation unless @direct_translation.nil?

            domain = edges.first&.dig(:translation)&.domain
            VERIFIED.include?(domain)
          end

          # The head SQL as one step, or nil when the chain cannot be composed exactly.
          #
          # @param aggregate [#name, #storage_name] the aggregate whose head is read
          # @param era [Integer] the era the head is read for
          # @param edges [Array<Hash>] the chain reaching `era`
          # @return [String, nil] the SQL; nil when a link needs the chain
          def direct_chain_sql(aggregate, era, edges)
            names = names_by_era(aggregate, edges)
            composed = composed_by_era(aggregate, edges)
            return unless composed

            tail = latest_per_id(target_tail_sql(names, era, edges))
            format(DIRECT_SQL, tail: tail, state: direct_state_sql(composed))
          end

          private

          # The aggregate's rules from each held era to the last, keyed by that era; nil when any
          # suffix of the chain refuses to compose.
          def composed_by_era(aggregate, edges)
            translations = edges.map { |edge| edge[:translation] }
            (1..translations.size).to_h do |held|
              composed = Translation::Compose.compose(**compose_arguments(translations.drop(held - 1)))
              [held, composed.for_aggregate(aggregate.name)]
            end
          rescue Runtime::WiringError
            nil
          end

          def compose_arguments(chain)
            { domain: chain.first.domain, from: chain.first.from, to: chain.last.to, chain: chain }
          end

          # `state` itself when no era's rows change, else one case per era that does.
          def direct_state_sql(composed)
            cases = composed.filter_map do |held, declared|
              "WHEN era = #{held} AND operation = 'save' THEN #{rules_expression(declared)}" if declared
            end
            cases.empty? ? "state" : "CASE #{cases.join(" ")} ELSE state END"
          end
        end
      end
    end
  end
end
