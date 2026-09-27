require_relative "../../lineage"
require_relative "../../era_guard"
require_relative "../../../../../../runtime/identity"
require_relative "../../../../../../runtime/registry"
require_relative "../../translation/audit"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # What a mint must prove first: the edge covers the whole diff, no identity path was
        # re-keyed, and the audit's first two layers pass over the compiled chain.
        module CoverageCheck
          # Refuses a mint whose translation edge leaves any part of the shape change unexplained.
          #
          # Every vanished or retyped path in the held-to-current diff must be explained and every
          # held aggregate claimed; the refusal is EraGuard's own, byte for byte.
          #
          # @param registry [Runtime::Registry] where translations may claim a held aggregate
          # @param bluebook [Bluebook::Chapter] the domain as currently declared
          # @param held_bluebook [Bluebook::Chapter] the domain as the latest held era declares it
          # @param edge [Bluebook::Translation] the one edge leaving the latest held era
          # @raise [Runtime::WiringError] on an unruled identity change or an uncovered path
          def check_coverage!(registry, bluebook, held_bluebook, edge)
            bluebook.aggregates.each do |aggregate|
              rules = Ports::Persistence::Lineage.from_declared(edge.for_aggregate(aggregate.name), aggregate.name)
              held_aggregate = held_bluebook.aggregate(rules&.ancestor_name || aggregate.name)
              next unless held_aggregate

              check_identity_unchanged!(bluebook, aggregate, held_aggregate, rules)
              uncovered = Runtime::EraGuard.uncovered_attributes(aggregate, held_aggregate, rules)
              Runtime::EraGuard.refuse_uncovered!(bluebook, aggregate, uncovered) unless uncovered.empty?

              unsafe = Runtime::EraGuard.unsafe_additions(aggregate, held_aggregate, rules)
              Runtime::EraGuard.refuse_unsafe_addition!(bluebook, aggregate, unsafe) unless unsafe.empty?
            end
            Runtime::EraGuard.check_vanished_aggregates!(registry, bluebook, held_bluebook)
          end

          # Refuses a mint that changes an aggregate's identity paths without declaring a `rekey`.
          #
          # Stored ids were fixed under the prior key, so the edge must declare a `rekey` for it;
          # `rules.rekey?` is the one source of truth for that fact.
          #
          # @param bluebook [Bluebook::Chapter] the domain, named in the refusal
          # @param aggregate [Bluebook::Aggregate] the aggregate as currently declared
          # @param held_aggregate [Bluebook::Aggregate] the same aggregate in the held era
          # @param rules [Ports::Persistence::Lineage, nil] the edge's rules; nil excuses nothing
          # @raise [Runtime::WiringError] if the identity paths differ and no `rekey` is declared
          def check_identity_unchanged!(bluebook, aggregate, held_aggregate, rules)
            # Full path lists, not the single-head shortcut: it is nil for every composite identity
            # and would let two different composites compare equal.
            return if held_aggregate.identity_paths == aggregate.identity_paths
            return if rules&.rekey?

            held_identity = Runtime::Identity.reading(held_aggregate)
            current_identity = Runtime::Identity.reading(aggregate)
            raise Runtime::WiringError,
                  "cannot mint an era for #{bluebook.name}::#{aggregate.name}: its identity path changed " \
                  "(#{held_identity} → #{current_identity}), and that is a re-keying, not a translation — " \
                  "stored ids were minted under #{held_identity}, and no rule declares rows the same " \
                  "entity under a new key. Keep the identity path, declare a rekey rule, or migrate the " \
                  "data explicitly"
          end

          # Previews each aggregate's translated head through the pending chain and audits it.
          # Runs before anything is minted, so a refusal leaves no half-born era.
          #
          # @param bluebook [Bluebook::Chapter] the domain as currently declared
          # @param lineage [Adapters::PostgresEra::Lineage] the domain's lineage, on an open db
          # @param chain [Array<Hash>] the full edge chain ending in `edge`, per `edge_chain`
          # @param ordinal [Integer] the ordinal of the era about to be minted
          # @param edge [Bluebook::Translation] the pending edge
          # @raise [Runtime::WiringError] if a preview query fails or the audit reports a violation
          # @raise [PG::Error] if Postgres refuses the "before" query
          def audit!(bluebook, lineage, chain, ordinal, edge)
            violations = []
            bluebook.aggregates.each do |aggregate|
              declared = edge.for_aggregate(aggregate.name)
              after = begin
                lineage.translated_latest(aggregate, ordinal, chain)
              rescue PG::Error => e
                raise Runtime::WiringError, "cannot mint era #{ordinal} of #{bluebook.name}: #{e.message.strip}"
              end
              before = if chain.size > 1
                         lineage.translated_latest(aggregate, ordinal, chain[0..-2])
                       else
                         lineage.ancestor_latest(aggregate, ordinal, chain)
                       end
              verdict = Translation::Audit.check(aggregate: aggregate, declared: declared, before: before, after: after)
              violations.concat(verdict.violations)
            end
            return if violations.empty?

            raise Runtime::WiringError,
                  "cannot mint era #{ordinal} of #{bluebook.name}: the audit refused —\n  - #{violations.join("\n  - ")}"
          end
        end
      end
    end
  end
end
