require_relative "../lineage"
require_relative "../../../../../../runtime/registry"
require_relative "../../translation/audit"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Tail-merge (hecks merge_tail): interleaves the stale world's post-cut writes into the
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

            chain = merge_chain(registry, bluebook, lineage.eras)
            lineage.merge_tail!(aggregates: bluebook.aggregates, edges: chain, winners: winners,
                                audit: head_audit(db, lineage, bluebook))
          ensure
            db&.close
          end

          private

          # The edge chain from era 1 to the latest era.
          def merge_chain(registry, bluebook, held)
            raise Runtime::WiringError, "nothing to merge — #{bluebook.name} stands at era 1" if held.size < 2

            edge_chain(registry, bluebook, held[0..-2], held.last[:label])
          end

          # The audit the merge runs over the merged heads, answering every violation found.
          def head_audit(db, lineage, bluebook)
            -> { bluebook.aggregates.flat_map { |aggregate| head_violations(db, lineage, aggregate) } }
          end

          def head_violations(db, lineage, aggregate)
            view = PG::Connection.quote_ident(lineage.head_view(aggregate.storage_name))
            rows = db.exec("SELECT id, state FROM #{view}").to_h { |row| [row["id"], JSON.parse(row["state"])] }
            Translation::Audit.check(aggregate: aggregate, declared: nil, before: rows, after: rows).violations
          end
        end
      end
    end
  end
end
