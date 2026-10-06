# frozen_string_literal: true

require "json"
require "time"
require_relative "held_domain"
require_relative "edge_audit"
require_relative "compaction"
require_relative "../git"

module Hecks
  module Adapters
    class JournalStore
      # The changes the journal store makes once `Era.Permit` has let one through.
      #
      # The rules that need no database are `given`s of the Era commands, including that a
      # re-attested text differs from its digest and keeps the era's shape. What stays here is what
      # only the database can enforce: the connection's write fence, the per-domain advisory lock
      # and its timeout, the append-only re-attestation, the audit that rolls a merge back, the
      # monotonic `compacted_through` floor and the row-level-security delete check.
      module Changes
        # Makes the change the record asks for.
        #
        # A change is made only for a record `Era.Permit` admitted, whichever way `apply` is asked.
        #
        # @param held [Hash] the `Era` record
        # @return [Hash{Symbol => Hash}] `report:` what was done, as the script said it
        # @raise [Runtime::WiringError] if the record was not admitted, or the database or an
        #   era's own guard refuses the change
        # @raise [Runtime::NotFound] if the domain cannot be loaded
        def apply(**held)
          unless plain(held[:status]) == "admitted"
            raise Runtime::WiringError,
                  "the change was not admitted (status #{plain(held[:status]).inspect}): " \
                  "only an admitted change is made"
          end

          { report: { value: send(:"apply_#{plain(held[:operation])}", held) } }
        end

        private

        def apply_hold_first(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          domain.writing do |lineage|
            raise Runtime::WiringError, "#{domain.bluebook.name} already holds an era" unless lineage.eras.empty?

            lineage.hold_first!(domain.source_text, projection: domain.shape)
          end
          "#{domain.bluebook.name} holds era 1 now."
        end

        def apply_merge_tail(held)
          domain = HeldDomain.open(plain(held[:domain]))
          named = winners(held)
          diverged = domain.writing { |lineage| diverged_writes(domain, lineage) }
          PostgresEra::LineageManager.merge!(registry: domain.registry, bluebook: domain.bluebook,
                                             settings: domain.settings, winners: named)
          ["#{domain.bluebook.name}: #{diverged} post-cut write#{"s" unless diverged == 1} in ancestor " \
           "eras before the merge",
           "merged — the head now interleaves both worlds by their recorded ordinals",
           *named.map { |id, side| "  winner #{id}=#{side} appended as the newest row" }].join("\n")
        end

        def diverged_writes(domain, lineage)
          eras = domain.held_eras(lineage)
          eras.size > 1 ? (1...eras.last[:ordinal]).sum { |era| lineage.diverged_count(era) } : 0
        end

        def apply_reattest(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          ordinal = plain(held[:era])
          domain.writing { |lineage| reattest(domain, lineage, ordinal) }
        end

        def reattest(domain, lineage, ordinal)
          lineage.raw_era(ordinal) or raise Runtime::NotFound, "#{domain.bluebook.name} holds no era #{ordinal}"
          fresh = lineage.reattest!(ordinal)
          "ATTESTED: era #{ordinal} re-frozen as #{fresh[0, 12]}… — the old and new digests are recorded."
        end

        def apply_backfill_projections(held)
          domain = HeldDomain.open(plain(held[:domain]), mode: :bare)
          domain.writing { |lineage| backfill(domain, lineage) }
        end

        def backfill(domain, lineage)
          missing = -> { missing_projections(lineage) }
          before = missing.call
          return "#{domain.bluebook.name}: every held era already carries a projection — nothing to do." if before.zero?

          begin
            # Raises on the first row whose own digest check fails: a tampered row, not a merely
            # legacy one, which backfilling must not paper over.
            lineage.eras
          rescue Runtime::WiringError => e
            raise Runtime::WiringError, "#{domain.bluebook.name}: stopped at a row that isn't merely legacy — " \
                                        "it fails its own integrity check: #{e.message} — resolve that first " \
                                        "(`hecks reattest`), then run this again for the remaining rows."
          end
          done = before - missing.call
          "#{domain.bluebook.name}: backfilled #{done} era#{"s" unless done == 1} — every row now carries a projection."
        end

        def missing_projections(lineage)
          lineage.db.exec_params(
            "SELECT count(*)::int AS n FROM hecks_eras WHERE domain = $1 AND held_projection IS NULL",
            [lineage.domain]
          )[0]["n"].to_i
        end

        def apply_compact(held) = apply_compaction(held, :entries)

        def apply_compact_heki(held) = apply_compaction(held, :heki)

        def apply_compaction(held, kind)
          Compaction.new(plain(held[:domain]), aggregates: names(held[:aggregates]), kind: kind).apply!.join("\n")
        end

        # Writes `translations/<edge>.approval`; the host reads it at its next boot.
        def apply_approve_translation(held)
          domain = HeldDomain.open(plain(held[:domain]))
          finding = domain.reading { |lineage| audited_edge(domain, lineage) }
          document = Translation::ApprovalFile.build(
            edge: finding.edge, approved_by: Git.new.identity(chdir: domain.directory),
            approved_at: Time.now.utc.iso8601, rehearsal: rehearsal_block(held)
          )
          path = Translation::ApprovalFile.write!(domain.directory, finding.edge, document)
          "approval of edge #{document["edge"]} written to #{path} (digest #{document["edge_digest"][0, 12]}…, " \
            "by #{document["approved_by"]}). Commit it with the edge; the host applies it at its next boot."
        end

        def audited_edge(domain, lineage)
          eras = domain.held_eras(lineage)
          finding = eras.empty? ? nil : EdgeAudit.call(domain, lineage, eras)
          raise Runtime::WiringError, "#{domain.bluebook.name} has no edge to approve" unless finding
          raise Runtime::WiringError, "#{finding.report}\nAUDIT REFUSED." unless finding.ok

          finding
        end
      end
    end
  end
end
