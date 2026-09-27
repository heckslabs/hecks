require_relative "../lineage"
require_relative "../../../../../../runtime/registry"
require_relative "../../translation/audit"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Tail-merge (bin/merge_tail): interleaves the stale world's post-cut writes into the
        # head by global ordinal, audited, in one transaction.
        module MergeCoordinator
          # Merges writes old checkouts made after the last mint into the current era's head.
          #
          # @param winners [Hash{String => String}] record id to `"old"` or `"new"`, naming
          #   which world's record wins for each id both worlds touched since the cut
          # @return [true] when the merge committed
          # @raise [Runtime::WiringError] if the domain stands at era 1, the edge chain is
          #   broken, a contested record has no winner, or the audit reports violations;
          #   every refusal rolls the merge back
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
