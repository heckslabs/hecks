# frozen_string_literal: true

require "digest"
require "json"
require_relative "held_domain"
require_relative "edge_audit"
require_relative "compaction"

module Hecks
  module Adapters
    class JournalStore
      # The facts the journal store reports about a change before it is made, for the rules of
      # Custodian's `Era.Permit` to hold against. Nothing here writes: an examination reads the
      # domain and its journal and answers numbers and yes-or-no.
      module Examination
        # What every fact is until an examination finds otherwise.
        NEUTRAL = {
          capable: false, held: 0, forks: 0, contested: 0, edges: 0, bound: 0, candidates: 0,
          audited: false, rehearsal_needed: false, rehearsal_recorded: false,
          drifted: false, loadable: false, shape_kept: false
        }.freeze

        # Examines the domain a change was asked for.
        #
        # @param held [Hash] the `Era` record: `operation`, `domain`, and whichever of `winners`,
        #   `era`, `aggregates` and the rehearsal fields the request carried
        # @return [Hash{Symbol => Hash}] every fact, as `{ value: x }`, and the request's own
        #   `operation`, which the reactions to the examination read
        # @raise [Runtime::NotFound] if the domain cannot be loaded or has no such era
        def examine(**held)
          found = send(:"examine_#{plain(held[:operation])}", held)
          NEUTRAL.merge(found).transform_values { |fact| { value: fact } }
                 .merge(operation: { value: plain(held[:operation]) })
        end

        private

        def examine_hold_first(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          return {} unless domain.capable?

          { capable: true, held: domain.reading { |lineage| domain.held_eras(lineage).size } }
        end

        def examine_merge_tail(held)
          domain = HeldDomain.open(plain(held[:domain]))
          return {} unless domain.capable?

          domain.reading do |lineage|
            eras = domain.held_eras(lineage)
            forks = forks_in(domain, eras)
            unresolved = eras.size > 1 && forks.zero? ? unresolved_conflicts(domain, lineage, eras, winners(held)) : 0
            { capable: true, held: eras.size, forks: forks, contested: unresolved }
          end
        end

        def examine_reattest(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          return {} unless domain.capable?

          ordinal = plain(held[:era])
          era = domain.reading { |lineage| raw_era(domain, lineage, ordinal) }
          { capable: true }.merge(text_facts(era))
        end

        # Whether the held text drifted from its digest and, if so, whether it still loads and
        # still projects to the shape the era froze with. A text that matches its digest has
        # nothing to attest, so its shape is not examined.
        def text_facts(era)
          return {} if era[:held_digest] == Digest::SHA256.hexdigest(era[:held_text])

          found = Translation::Reattest.verdict(
            text: era[:held_text], stored_hash: era[:hash],
            stored_projection: era[:held_projection] && JSON.parse(era[:held_projection])
          )
          { drifted: true, loadable: found != :unloadable, shape_kept: %i[cosmetic unnamed].include?(found) }
        end

        def examine_backfill_projections(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          { capable: domain.capable? }
        end

        def examine_compact(held) = examine_compaction(held, :entries)

        def examine_compact_heki(held) = examine_compaction(held, :heki)

        def examine_compaction(held, kind)
          compaction = Compaction.new(plain(held[:domain]), aggregates: names(held[:aggregates]), kind: kind)
          { candidates: compaction.candidates.size, bound: compaction.bound.size }
        end

        def examine_approve_translation(held)
          domain = HeldDomain.open(plain(held[:domain]))
          return {} unless domain.capable?

          domain.reading do |lineage|
            eras = domain.held_eras(lineage)
            finding = eras.empty? ? nil : EdgeAudit.call(domain, lineage, eras)
            next { capable: true, held: eras.size } unless finding

            { capable: true, held: eras.size, edges: finding.leaving, audited: finding.ok }.merge(rehearsal_facts(finding, held))
          end
        end

        def rehearsal_facts(finding, held)
          {
            rehearsal_needed:   Translation::ApprovalFile.needs_rehearsal?(finding.edge),
            rehearsal_recorded: Translation::ApprovalFile.rehearsed?(rehearsal_block(held))
          }
        end

        # How many eras, before the latest, do not have exactly one edge leading to the next.
        def forks_in(domain, eras)
          eras.each_cons(2).count do |from, to|
            leaving = domain.registry.translations.select do |edge|
              edge.domain == domain.bluebook.name && edge.from == from[:label]
            end
            leaving.size != 1 || leaving.first.to != to[:label]
          end
        end

        # Records both worlds wrote since the cut that no winner was named for.
        def unresolved_conflicts(domain, lineage, eras, named)
          latest = eras.last
          chain = PostgresEra::LineageManager.edge_chain(domain.registry, domain.bluebook, eras[0..-2], latest[:label])
          conflicts = domain.bluebook.aggregates.flat_map do |aggregate|
            lineage.conflict_ids(aggregate, chain, latest[:ordinal], latest[:watermark].to_i)
          end
          conflicts.count { |_, id| !named.key?(id) }
        end
      end
    end
  end
end
