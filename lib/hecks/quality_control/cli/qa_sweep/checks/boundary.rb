# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module Checks
        # The two checks a sweep makes once rather than per seed: the verbs the Rust generator
        # skipped, and the ancestor eras' unmerged writes.
        module Boundary
          private

          # Once-per-sweep report of verbs skipped as not generated: held with the full list,
          # surprised if any skipped verb's construct is outside the documented boundary.
          def structural_skip_check(differ, binary, boundary)
            skipped = differ.structural_skips.to_a.sort
            gaps = Hecks::Fuzzing::RustGapManifest.for_binary(binary)
            attributed = Hecks::Fuzzing::StructuralSkips.attribute(gaps, skipped)
            outside = Hecks::Fuzzing::StructuralSkips.outside_boundary(attributed, boundary)
            structural_skip_report(skipped, attributed, outside.map { |e| structural_divergence(e) })
          end

          def structural_divergence(entry)
            declares = entry[:constructs].empty? ? "nothing" : entry[:constructs].join(",")
            { field: "structural_skip", verb: entry[:verb], constructs: entry[:constructs],
              detail: "#{entry[:verb]} was skipped as not generated (construct: #{declares}), outside " \
                      "STRUCTURAL_REFUSAL_BOUNDARY — a codegen regression or a new gap, not a documented boundary" }
          end

          def structural_skip_report(skipped, attributed, divergences)
            listing = attributed.map { |e| "#{e[:verb]} [#{e[:constructs].join(",")}]" }.join("; ")
            { mode: :structural_skip_report,
              subject: "[structural_skip_report] structurally skipped #{skipped.size} verb(s): [#{listing}]",
              expectation: "every named query/read model skipped because manifest.json declares it not " \
                           "generated names a construct inside QualityControlDials::STRUCTURAL_REFUSAL_BOUNDARY",
              divergences: divergences, clean: divergences.empty?,
              observation: structural_observation(skipped, divergences) }
          end

          def structural_observation(skipped, divergences)
            return "all #{skipped.size} inside the documented boundary" if divergences.empty?

            "#{divergences.size} outside the boundary"
          end

          # Seedless, once per sweep: audits the target's own persisted lineage. Nothing to audit
          # is a note, not a finding.
          def era_boundary_check(domain_path)
            result = Hecks::Fuzzing::EraBoundary.diverged_ancestor_writes(domain_path)
            return unchecked_era_boundary(domain_path, result) unless result[:checked]

            divergences = era_boundary_divergences(result)
            { mode: :era_boundary, subject: "[era_boundary] #{File.basename(domain_path)} — ancestor-era audit " \
                                            "(#{result[:era_count]} era(s) on record)",
              expectation: MODE_EXPECTATIONS.fetch(:era_boundary), divergences: divergences,
              clean: divergences.empty?,
              observation: era_observation(divergences, result) }
          end

          def era_observation(divergences, result)
            return "no ancestor era holds an unmerged write" if divergences.empty?

            "#{result[:diverged_total]} diverged"
          end

          def era_boundary_divergences(result)
            return [] unless result[:diverged_total].positive?

            [{ field: "era_boundary", breakdown: result[:breakdown],
               detail: "#{result[:diverged_total]} post-cut write(s) across #{result[:era_count]} era(s) " \
                       "that nothing has ever merged forward — hecks merge_tail <this target's own domain " \
                       "path> is the fix; see this script's own header on `era_boundary` for the class of " \
                       "bug this is" }]
          end

          # Nothing to audit and could not audit stay apart: `not_applicable` logs no `Check`, while
          # an error is a finding, so an unreachable database never counts as a held `Check` toward
          # the streak.
          def unchecked_era_boundary(domain_path, result)
            if result[:kind] == :not_applicable
              return { mode: :era_boundary, skip: true, observation: "not applicable — #{result[:reason]}" }
            end

            { mode: :era_boundary, subject: "[era_boundary] #{File.basename(domain_path)} — ancestor-era audit",
              expectation: MODE_EXPECTATIONS.fetch(:era_boundary),
              divergences: [{ field: "era_boundary_unchecked", detail: result[:reason] }], clean: false,
              observation: "could not audit — #{result[:reason]}" }
          end
        end
      end
    end
  end
end
