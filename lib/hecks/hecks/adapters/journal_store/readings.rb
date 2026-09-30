# frozen_string_literal: true

require "json"
require "digest"
require_relative "held_domain"
require_relative "edge_audit"
require_relative "compaction"

module Hecks
  module Adapters
    class JournalStore
      # The queries the journal store answers: what would be scaffolded, how the audit reads, an
      # era's held text, and what compacting would delete.
      #
      # A reading never writes. It provisions nothing, holds no era, names none and writes no file;
      # a domain that holds no era answers that it holds none, and only `hold_first` holds one.
      # What a reading refuses is a `Runtime::NotFound`, the refusal a launcher words as an answer.
      module Readings
        # Words the answer for a domain that holds no era.
        #
        # @param name [String] the domain's name
        # @param path [String] the domain path, as the operator typed it
        # @return [String] the sentence
        def self.no_era(name, path)
          "#{name} holds no era yet. `hecks hold_first #{path} --confirm` holds the first."
        end

        # The edge file that would lead the latest held era to the current shape, as its text.
        #
        # @param domain [Hash, String] the domain directory
        # @return [Hash] `text:` the `.bluebook` text, under comments saying where to save it and
        #   what is left to decide
        # @raise [Runtime::NotFound] if the domain holds no eras, or cannot be loaded
        def scaffold_translation(domain:)
          answering do
            held = HeldDomain.open(plain(domain), mode: :scaffold)
            refuse_incapable!(held)
            held.reading { |lineage| scaffold(held, lineage, plain(domain)) }
          end
        end

        # The audit of the edge that leads the latest held era to the current shape.
        #
        # @param domain [Hash, String] the domain directory
        # @return [Hash] `text:` the report, ending in what approving needs
        # @raise [Runtime::NotFound] if the audit refuses, or no edge leads to the current shape
        def audit_translation(domain:)
          answering do
            held = HeldDomain.open(plain(domain))
            refuse_incapable!(held)
            held.reading { |lineage| audit(held, lineage, plain(domain)) }
          end
        end

        # An era's held text as it now stands, and whether it still matches its digest.
        #
        # @param domain [Hash, String] the domain directory
        # @param era [Hash, Integer] the era's ordinal
        # @return [Hash] `text:` the digests and the text a person reads before attesting to it
        # @raise [Runtime::NotFound] if the domain holds no such era
        def attestation(domain:, era:)
          answering do
            held = HeldDomain.open(plain(domain), mode: :bare)
            refuse_incapable!(held)
            held.reading { |lineage| attest(held, lineage, plain(era)) }
          end
        end

        # What compacting the domain's journals would delete, without deleting anything.
        #
        # @param domain [Hash, String] the domain directory
        # @param aggregates [Hash, String, nil] aggregate names, comma separated
        # @return [Hash] `text:` one line per journal
        # @raise [Runtime::NotFound] if the domain cannot be loaded
        def compaction(domain:, aggregates: nil)
          answering do
            lines = %i[entries heki].flat_map do |kind|
              Compaction.new(plain(domain), aggregates: names(aggregates), kind: kind).preview
            end
            lines.empty? ? "no journal of #{plain(domain)} can be compacted" : lines.join("\n")
          end
        end

        private

        # Words a lower layer's refusal as the one a query is refused with. `pg` is loaded lazily,
        # so its error is only named once something has connected.
        def answering
          { text: yield }
        rescue *lower_refusals => e
          raise Runtime::NotFound, e.message.strip
        end

        def lower_refusals
          [Runtime::WiringError, Bluebook::DSL::Malformed, ArgumentError, *(PG::Error if defined?(PG))]
        end

        def refuse_incapable!(held)
          raise Runtime::NotFound, held.incapable_reason unless held.capable?
        end

        def scaffold(held, lineage, path)
          eras = held.held_eras(lineage)
          return Readings.no_era(held.bluebook.name, path) if eras.empty?

          latest = held.named(eras.last)
          shadow = PostgresEra::LineageManager.shadow(latest[:held_text])
          if Runtime::StorageShape.project(shadow) == held.shape
            return "#{held.bluebook.name} matches era #{latest[:ordinal]} — nothing to scaffold."
          end

          edge_text(held, latest, Translation::Scaffold.diff(shadow, held.bluebook))
        end

        def edge_text(held, latest, diffed)
          label = Runtime::StorageShape.mint_hash(held.bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
          edge = Translation::Scaffold::Edge.new(
            domain: held.bluebook.name, from: latest[:label], to: label, ordinal: latest[:ordinal] + 1,
            label: label, aggregates: diffed[:aggregates], retired: diffed[:retired]
          )
          text = Translation::Scaffold.render(edge)
          [*scaffold_notes(edge, text, diffed[:unclaimed]), text].join("\n")
        end

        def scaffold_notes(edge, text, unclaimed)
          unresolved = text.scan(/^\s*unresolved /).size
          notes = ["# Save as translations/#{edge.ordinal}-#{edge.label}.bluebook."]
          notes << "# #{unresolved} unresolved: decide what each became, then boot." if unresolved.positive?
          unclaimed.each do |name|
            notes << "# UNCLAIMED: #{name} existed and now doesn't, and its successor is ambiguous — add " \
                     "`aggregate \"NewName\", was: #{name.inspect}` (with its rules) or `retired #{name.inspect}`."
          end
          notes << "# 0 unresolved: this shape change costs one extra boot and no typing." if notes.size == 1
          notes
        end

        def audit(held, lineage, path)
          eras = held.held_eras(lineage)
          return Readings.no_era(held.bluebook.name, path) if eras.empty?

          finding = EdgeAudit.call(held, lineage, eras)
          return "#{held.bluebook.name} stands at era 1 — no edge to audit." unless finding
          raise Runtime::NotFound, "#{finding.report}\nAUDIT REFUSED." unless finding.ok

          [finding.report, audit_verdict(finding.edge, path)].join("\n")
        end

        def audit_verdict(edge, path)
          if Translation::ApprovalFile.needs_rehearsal?(edge)
            "AUDIT PASSED — this edge carries a compute or rekey rule, and the samples above are its ONLY " \
              "verification. If they show what you intended, rehearse it against a snapshot and run " \
              "`hecks approve_translation #{path} --confirm` with the rehearsal; the mint refuses until then."
          else
            "AUDIT PASSED — review the samples above; intent is yours to approve."
          end
        end

        def attest(held, lineage, ordinal)
          era = raw_era(held, lineage, ordinal)
          computed = Digest::SHA256.hexdigest(era[:held_text])
          name = "#{held.bluebook.name} era #{ordinal}"
          return "#{name}: the held text matches its digest — nothing to re-attest." if era[:held_digest] == computed

          [
            "#{name}: the held text does NOT match its recorded digest.",
            "  recorded: #{era[:held_digest] || '(none)'}", "  computed: #{computed}", shape_line(held, era, ordinal),
            "The held text AS IT NOW STANDS — the original is gone; this is what you would be attesting to:",
            "─" * 72, era[:held_text], "─" * 72,
            "Read it, then `hecks reattest #{held.bluebook.name} era=#{ordinal} --confirm` accepts it."
          ].join("\n")
        end

        def shape_line(held, era, ordinal)
          verdict = Translation::Reattest.shape_guard!(
            domain: held.bluebook.name, ordinal: ordinal, text: era[:held_text], stored_hash: era[:hash],
            stored_projection: era[:held_projection] && JSON.parse(era[:held_projection])
          )
          if verdict == :cosmetic
            "  shape:    unchanged — the edit is cosmetic (the text still projects to era #{ordinal}'s minted name)"
          else
            "  shape:    era #{ordinal} was never named, so no shape comparison is possible — read carefully"
          end
        end
      end
    end
  end
end
