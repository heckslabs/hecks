require_relative "../lineage"
require_relative "../../../../../../runtime/registry"
require_relative "../../translation/audit"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Tail-merge, driven from bin/merge_tail: interleave the old
        # world's post-cut writes into the head by their recorded global
        # ordinals, under the full audit, in one transaction.
        module MergeCoordinator
          def merge!(registry:, bluebook:, settings:, winners: {})
            db = PostgresEra.connect_for(bluebook.name, settings)
            lineage = Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
            lineage.ensure_base!

            held = lineage.eras
            raise Runtime::WiringError, "nothing to merge — #{bluebook.name} stands at era 1" if held.size < 2

            latest = held.last
            chain = edge_chain(registry, bluebook, held[0..-2], latest[:label])

            audit = lambda do
              violations = []
              bluebook.aggregates.each do |aggregate|
                rows = db.exec("SELECT id, state FROM #{PG::Connection.quote_ident(lineage.head_view(aggregate.storage_name))}")
                         .to_h { |row| [row["id"], JSON.parse(row["state"])] }
                verdict = Translation::Audit.check(aggregate: aggregate, declared: nil, before: rows, after: rows)
                violations.concat(verdict.violations)
              end
              violations
            end

            lineage.merge_tail!(aggregates: bluebook.aggregates, edges: chain, winners: winners, audit: audit)
          ensure
            db&.close
          end
        end
      end
    end
  end
end
