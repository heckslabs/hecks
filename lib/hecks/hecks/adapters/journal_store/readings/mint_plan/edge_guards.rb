# frozen_string_literal: true

require_relative "../../edge_audit"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The guards on the edge a mint would take, each the very function the mint runs: the
          # shared decision's refusal (`LineageManager.resolve_edge!`, which words a missing or a
          # duplicate edge), the coverage check (`check_coverage!`) and the translation audit the
          # rehearsal runs over the rows (`EdgeAudit`), here over the live store in place.
          class EdgeGuards
            LATER = %w[coverage audit].freeze

            # @param report [Report] where each guard is recorded
            # @param held [HeldDomain] the loaded domain
            # @param lineage [Lineage] a read-only lineage over the store
            def initialize(report, held, lineage)
              @report = report
              @held = held
              @lineage = lineage
            end

            # @param eras [Array<Hash>] the held eras
            # @param verdict [LineageManager::MintDecision::Verdict] the latest era's decision
            # @return [Object, nil] the edge the mint would take; nil when a guard refused
            def call(eras, verdict)
              latest = @held.named(eras.last)
              edge = decided(latest, verdict)
              return stop(LATER, "the edge guard refused") unless edge
              return stop(%w[audit], "the coverage check refused") unless covered?(latest, edge)

              audit(eras, edge)
              edge
            end

            private

            def stop(names, why)
              @report.skip(names, why)
              nil
            end

            def decided(latest, verdict)
              if verdict.verdict == "would_mint"
                @report.add("edge", :pass, edge_words(verdict))
                return verdict.edge
              end

              @report.add("edge", :refuse, refusal(latest, verdict))
              nil
            end

            def edge_words(verdict)
              edge = verdict.edge
              "#{verdict.source} edge #{edge.from} -> #{edge.to}; #{verdict.edges.size} written edge(s) lead there"
            end

            # The words the mint refuses with, from its own function. The scaffold branch of that
            # function writes a file, so a run that asked for it is worded from the verdict instead.
            def refusal(latest, verdict)
              return "the decision is #{verdict.verdict}: #{verdict.reason}" if ENV["HECKS_SCAFFOLD"] == "1"

              PostgresEra::LineageManager.resolve_edge!(context(latest))
              "the decision is #{verdict.verdict}: #{verdict.reason}"
            rescue Runtime::WiringError => e
              e.message
            end

            def context(latest)
              PostgresEra::LineageManager::Context.new(
                registry: @held.registry, bluebook: @held.bluebook, current_text: nil, lineage: @lineage, role: nil,
                directory: @held.directory, latest: latest
              )
            end

            def covered?(latest, edge)
              held = PostgresEra::LineageManager.held_bluebook(latest)
              status = @report.check("coverage") do
                PostgresEra::LineageManager.check_coverage!(@held.registry, @held.bluebook, held, edge)
                [:pass, "no change in the shape goes unexplained by the edge"]
              end
              status == "pass"
            end

            def audit(eras, edge)
              @report.check("audit") do
                finding = EdgeAudit.call(@held, @lineage, eras, edge: edge)
                finding.ok ? [:pass, audited(finding)] : [:refuse, refused(finding)]
              end
            end

            def audited(finding)
              rows = finding.after.values.sum(&:size)
              "Ruby audit over #{rows} translated record(s), in place, read-only; parity not run: " \
                "parity needs the full rehearsal"
            end

            def refused(finding) = "the audit refused: #{finding.refusals.first(5).join("; ")}"
          end
        end
      end
    end
  end
end
