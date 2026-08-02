require_relative "../../../../ports/persistence/lineage"
require_relative "../../../../runtime/era_guard"
require_relative "../../../../runtime/identity"
require_relative "../../../../runtime/registry"
require_relative "../../../../translation/audit"

module Hecksagain
  module Adapters
    class Postgres
      module LineageManager
        # What a mint must prove before it may happen: the edge covers
        # the whole diff, no identity path was re-keyed, and the audit's
        # first two layers pass over the LIVE compiled chain.
        module CoverageCheck
          # Layer 1 against THIS edge specifically: every vanished or
          # retyped path in the held→current diff must be explained, and
          # every held aggregate must still be claimed. The refusal is
          # EraGuard's own, byte for byte.
          def check_coverage!(registry, bluebook, held_bluebook, edge)
            bluebook.aggregates.each do |aggregate|
              rules = Ports::Persistence::Lineage.from_declared(edge.for_aggregate(aggregate.name), aggregate.name)
              held_aggregate = held_bluebook.aggregate(rules&.ancestor_name || aggregate.name)
              next unless held_aggregate

              check_identity_unchanged!(bluebook, aggregate, held_aggregate)
              uncovered = Runtime::EraGuard.uncovered_attributes(aggregate, held_aggregate, rules)
              Runtime::EraGuard.refuse_uncovered!(bluebook, aggregate, uncovered) unless uncovered.empty?
            end
            Runtime::EraGuard.check_vanished_aggregates!(registry, bluebook, held_bluebook)
          end

          # An identity-path change is a RE-KEYING, not a translation:
          # stored ids were fixed at write time under the old key, the
          # audit's id-set conservation and the merge's conflict INTERSECT
          # both assume ids are stable, and no rule in the edge language
          # says "these rows are the same entity under a new key." Until a
          # real re-keying story exists, this refuses in its own words
          # rather than minting a technically-valid era whose conflict
          # detection is meaningless.
          def check_identity_unchanged!(bluebook, aggregate, held_aggregate)
            # The FULL declared path lists, in declaration order — never the
            # single-head shortcut, which is nil for every composite identity
            # and so would let two different composites compare as unchanged.
            return if held_aggregate.identity_paths == aggregate.identity_paths

            held_identity = Runtime::Identity.reading(held_aggregate)
            current_identity = Runtime::Identity.reading(aggregate)
            raise Runtime::WiringError,
                  "cannot mint an era for #{bluebook.name}::#{aggregate.name}: its identity path changed " \
                  "(#{held_identity} → #{current_identity}), and that is a re-keying, not a translation — " \
                  "stored ids were minted under #{held_identity}, and no rule can declare rows the same " \
                  "entity under a new key. Keep the identity path, or migrate the data explicitly"
          end

          # Layers 1 and 2 of the audit, over the LIVE compiled chain —
          # before anything is minted, so a refusal leaves no half-born
          # era. (A convert meeting an unmapped value raises inside the
          # preview query itself: same rollback-shaped outcome.)
          def audit!(bluebook, lineage, chain, ordinal, edge)
            violations = []
            bluebook.aggregates.each do |aggregate|
              declared = edge.for_aggregate(aggregate.name)
              after = begin
                lineage.translated_latest(aggregate, ordinal, chain)
              rescue PG::Error => error
                raise Runtime::WiringError, "cannot mint era #{ordinal} of #{bluebook.name}: #{error.message.strip}"
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
