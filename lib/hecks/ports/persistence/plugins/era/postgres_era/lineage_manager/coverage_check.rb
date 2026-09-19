require_relative "../../lineage"
require_relative "../../era_guard"
require_relative "../../../../../../runtime/identity"
require_relative "../../../../../../runtime/registry"
require_relative "../../translation/audit"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # What a mint must prove before it may happen: the edge covers
        # the whole diff, no identity path was re-keyed, and the audit's
        # first two layers pass over the live compiled chain.
        module CoverageCheck
          # Refuses a mint whose translation edge leaves any part of the shape change
          # unexplained.
          #
          # Layer 1 against this edge specifically: every vanished or
          # retyped path in the held→current diff must be explained, and
          # every held aggregate must still be claimed. The refusal is
          # EraGuard's own, byte for byte.
          #
          # @param registry [Runtime::Registry] the registry whose loaded translations may
          #   claim a held aggregate through `was:` or `retired`
          # @param bluebook [Bluebook::Chapter] the domain as currently declared
          # @param held_bluebook [Bluebook::Chapter] the domain as the latest held era's
          #   text declares it (a shadow parse)
          # @param edge [Bluebook::Translation] the one edge leaving the latest held era
          # @return [void]
          # @raise [Runtime::WiringError] if an identity path changed without a `rekey`
          #   rule, a vanished or retyped path has no rule, a new required attribute has
          #   nothing to fill it, or a held aggregate is neither renamed nor retired
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

          # Refuses a mint that changes an aggregate's identity paths without declaring
          # a `rekey`.
          #
          # An identity-path change is a re-keying, not an ordinary
          # translation — stored ids were fixed at write time under the old
          # key, so this refuses unless the edge declares a `rekey` for
          # this aggregate covering exactly that. `rules.rekey?` (see
          # `Ports::Persistence::Lineage`'s own comment) is the single
          # source of truth every consumer of this fact asks — this is not
          # a second, independent check of `declared.rekeys`.
          #
          # @param bluebook [Bluebook::Chapter] the domain, named in the refusal
          # @param aggregate [Bluebook::Aggregate] the aggregate as currently declared
          # @param held_aggregate [Bluebook::Aggregate] the same aggregate as the held
          #   era's text declares it
          # @param rules [Ports::Persistence::Lineage, nil] the edge's rules for this
          #   aggregate; nil when the edge declares none, which cannot excuse a change
          # @return [nil] when the identity paths are unchanged or a `rekey` covers them
          # @raise [Runtime::WiringError] if the identity paths differ and no `rekey` rule
          #   is declared
          def check_identity_unchanged!(bluebook, aggregate, held_aggregate, rules)
            # The full declared path lists, in declaration order — never the
            # single-head shortcut, which is nil for every composite identity
            # and so would let two different composites compare as unchanged.
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

          # Previews every aggregate's translated head through the pending chain and
          # refuses the mint if the audit finds a violation.
          #
          # Layers 1 and 2 of the audit, over the live compiled chain —
          # before anything is minted, so a refusal leaves no half-born
          # era. (A convert meeting an unmapped value raises inside the
          # preview query itself: same rollback-shaped outcome.)
          #
          # @param bluebook [Bluebook::Chapter] the domain as currently declared
          # @param lineage [Adapters::PostgresEra::Lineage] the domain's lineage, on an open
          #   connection
          # @param chain [Array<Hash{Symbol => Bluebook::Translation}>] the full edge chain
          #   ending in `edge`, as `edge_chain` returns it
          # @param ordinal [Integer] the ordinal of the era about to be minted
          # @param edge [Bluebook::Translation] the pending edge, whose per-aggregate rules
          #   the audit checks
          # @return [nil] when no aggregate reports a violation
          # @raise [Runtime::WiringError] if Postgres refuses the translated preview query
          #   (a `convert` meeting an unmapped value, for one), or the audit reports any
          #   violation; the message lists them all
          # @raise [PG::Error] if Postgres refuses the "before" query; only the translated
          #   preview is rescued into a `Runtime::WiringError`
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
