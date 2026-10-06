# frozen_string_literal: true

require "json"
require_relative "../../tools"

module Hecks
  module Tools
    module TranslationAudit
      # Judges each aggregate across the edge, prints the verdicts and concludes the audit.
      module Verdicts
        # Prints each aggregate's verdict.
        #
        # @return [Boolean] whether any aggregate's audit was refused
        def report(bluebook, lineage, edge, era, chain)
          failed = false
          bluebook.aggregates.each do |aggregate|
            after, verdict = audit_aggregate(aggregate, lineage, edge, era, chain)
            print_verdict(bluebook, aggregate, edge, after, verdict)
            failed ||= !verdict.ok?
          end
          failed
        end

        # @return [Array(Array, Object)] the records after the edge, and the audit's verdict on them
        def audit_aggregate(aggregate, lineage, edge, era, chain)
          declared = edge.for_aggregate(aggregate.name)
          after = translated_after(lineage, aggregate, era, chain)
          before = records_before(lineage, aggregate, era, chain)
          [after, Hecks::Translation::Audit.check(aggregate: aggregate, declared: declared, before: before, after: after)]
        end

        # @return [Integer] the exit status
        def conclude(db, lineage, edge, failed, approve)
          if failed
            db.close
            puts "AUDIT REFUSED."
            return 1
          end

          needs_approval = edge.aggregates.any? { |declared| !declared.computes.empty? || !declared.rekeys.empty? }
          record_approval(lineage, edge) if needs_approval && approve
          db.close
          print_passed(needs_approval, approve)
          0
        end

        private

        def translated_after(lineage, aggregate, era, chain)
          lineage.translated_latest(aggregate, era, chain)
        rescue PG::Error => e
          abort "REFUSED: #{e.message.strip}"
        end

        def records_before(lineage, aggregate, era, chain)
          return lineage.translated_latest(aggregate, era, chain[0..-2]) if chain.size > 1

          lineage.ancestor_latest(aggregate, era, chain)
        end

        # @return [void]
        def print_verdict(bluebook, aggregate, edge, after, verdict)
          puts "── #{bluebook.name}::#{aggregate.name} (edge #{edge.from} → #{edge.to}, " \
               "#{after.size} record#{"s" unless after.size == 1})"
          verdict.violations.each { |violation| puts "   REFUSED: #{violation}" }
          print_losses(verdict)
          verdict.samples.each { |sample| print_sample(sample) }
        end

        def print_losses(verdict)
          puts "   dropped (declared data loss): #{verdict.dropped.join(", ")}" unless verdict.dropped.empty?
          return if verdict.unfed.empty?

          puts "   unfed (no rule, no default — add default: if required): #{verdict.unfed.join(", ")}"
        end

        def print_sample(sample)
          puts "   ##{sample[:id]}"
          puts "     before: #{JSON.generate(sample[:before])}" if sample[:before]
          puts "     after:  #{JSON.generate(sample[:after])}" if sample[:after]
        end

        # Binds to what was reviewed — this edge and the journal as it stands now — so it must
        # live in the database, not the repo.
        def record_approval(lineage, edge)
          lineage.record_approval!(
            from: edge.from, to: edge.to,
            edge_digest: Hecks::Translation::Audit.edge_digest(edge)
          )
        end

        def print_passed(needs_approval, approve)
          if needs_approval && approve
            puts "AUDIT PASSED — approval recorded in the database, bound to this edge and this journal."
            puts "A journal that advances before the mint invalidates it; re-run with --approve if that happens."
          elsif needs_approval
            puts "AUDIT PASSED — this edge carries a compute or rekey rule, and the samples above are " \
                 "its ONLY verification."
            puts "If they show what you intended, run again with --approve; the mint refuses until you do."
          else
            puts "AUDIT PASSED — review the samples above; intent is yours to approve."
          end
        end
      end
    end
  end
end
