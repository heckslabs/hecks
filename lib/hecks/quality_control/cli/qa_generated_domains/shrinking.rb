# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaGeneratedDomains
      # What happens to a domain that found something: shrunk to its minimal form, re-checked, and
      # written beside its blueprint and shrunk steps.
      module Shrinking
        private

        # @return [Array(Hash, Integer)] the smallest blueprint that still finds the same thing,
        #   and the candidate checks it took
        def shrink_domain(blueprint, found, root)
          match = { "mode" => found["mode"], "signature" => found["signature"] }
          current = blueprint
          attempts = 0
          loop do
            candidate, attempts = next_shrink(current, attempts, root, match)
            break unless candidate

            current = candidate
            break unless attempts < @options[:domain_shrink_budget]
          end
          [current, attempts]
        end

        # @return [Array(Hash, Integer)] the first smaller candidate that still finds the same thing
        #   (nil when none or the budget ran out), and the attempts so far
        def next_shrink(current, attempts, root, match)
          Generator.shrink_candidates(current).each do |candidate|
            return [nil, attempts] if attempts >= @options[:domain_shrink_budget]

            attempts += 1
            return [candidate, attempts] if evaluate(candidate, File.join(root, "candidate"), match: match)["status"] == "found"
          end
          [nil, attempts]
        end

        def record_finding(blueprint, result, root)
          minimal, attempts = shrink_domain(blueprint, result, root)
          final_root = File.join(root, "minimal")
          minimal, final = final_evaluation(blueprint, minimal, result, final_root)
          steps_file = write_finding(final, final_root)
          { forms: blueprint["forms"], root: final_root, dir: final["dir"], binary: final["binary"], final: final,
            options: @options, steps_file: steps_file, domain_attempts: attempts,
            size_before: Generator.removals(blueprint).size, size_after: Generator.removals(minimal).size }
        end

        # @return [Array(Hash, Hash)] the blueprint the finding is recorded for, and its final check
        def final_evaluation(blueprint, minimal, result, final_root)
          match = { "mode" => result["mode"], "signature" => result["signature"] }
          final = evaluate(minimal, final_root, match: match, shrink_budget: @options[:shrink_budget])
          return [minimal, final] if final["status"] == "found"

          [blueprint, evaluate(blueprint, final_root, shrink_budget: @options[:shrink_budget])]
        end

        # @return [String] the path of the shrunk steps file
        def write_finding(final, final_root)
          File.write(File.join(final_root, "finding.json"), JSON.pretty_generate(final.except("dir", "binary")))
          steps_file = File.join(final_root, "shrunk_steps.json")
          note = "hecks quality_control check_generated_domains finding"
          File.write(steps_file, JSON.pretty_generate(name: "qa_generated-shrunk", note: note,
                                                      steps: final.fetch("shrunk_steps") { final.fetch("steps", []) }))
          steps_file
        end
      end
    end
  end
end
