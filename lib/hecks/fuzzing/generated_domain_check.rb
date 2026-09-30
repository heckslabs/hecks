require "json"
require_relative "isolated_boot"
require_relative "sequence_generator"
require_relative "replay"
require_relative "shrinker"
require_relative "differential"

module Hecks
  module Fuzzing
    # The child-process half of `hecks quality_control check_generated_domains`: checks one
    # generated domain.
    #
    # One domain per process, since every generated domain is named `QaGenerated`.
    # A domain that fails to boot is `invalid` (a generator defect), not a finding.
    module GeneratedDomainCheck
      DIFFERENTIAL_MODES = %i[differential self_consistency properties_in_differential].freeze

      module_function

      # Checks one generated domain over up to `seeds` sequences, stopping at the first finding.
      #
      # With a compiled `binary` it diffs Ruby against Rust; without one it replays Ruby only.
      # `match` (`{"mode" =>, "signature" =>}`) keeps only a finding that still matches, so
      # domain-level shrinking can ask whether a smaller domain shows the same finding.
      #
      # @return [Hash] `"status"` is `"invalid"`, `"clean"` or `"found"`; a found finding is
      #   `#finding` merged with `"seeds_run"`, plus `"shrunk_steps"` if `shrink_budget` > 0
      def run(domain_path, seeds:, steps:, adversarial:, binary: nil, differ: nil, match: nil, shrink_budget: 0)
        error = boot_error(domain_path)
        return { "status" => "invalid", "error" => error } if error

        (1..seeds).each do |seed|
          finding = check_seed(domain_path, seed, steps, adversarial, binary, differ, match)
          next unless finding

          finding["shrunk_steps"] = shrink(domain_path, finding, binary, differ, shrink_budget) if shrink_budget.positive?
          return finding.merge("status" => "found", "seeds_run" => seed)
        end
        { "status" => "clean", "seeds_run" => seeds }
      end

      def boot_error(domain_path)
        IsolatedBoot.call(domain_path) { |copy| Hecks.boot(copy, environment: nil) }
        nil
      rescue StandardError, ScriptError => e
        "#{e.class}: #{e.message.lines.first&.strip}"
      end

      def check_seed(domain_path, seed, steps, adversarial, binary, differ, match)
        sequence = SequenceGenerator.generate(domain_path, seed: seed, steps: steps, adversarial: adversarial)
      rescue StandardError => e
        finding(seed, :generator, [{ field: "generator_crash", detail: "#{e.class}: #{e.message}" }], [], match)
      else
        outcomes(domain_path, sequence, binary, differ).each do |mode, divergences|
          found = finding(seed, mode, divergences, sequence, match)
          return found if found
        end
        nil
      end

      # Diffs against Rust when `binary` is given, otherwise replays Ruby only.
      def outcomes(domain_path, sequence, binary, differ)
        return Differential.diff(differ, domain_path, sequence, binary, modes: DIFFERENTIAL_MODES) if binary

        history = Replay.call(domain_path, sequence, self_consistency: true)
        { ruby_only:        Differential.property_divergences(history),
          self_consistency: Differential.self_consistency_divergences(history) }
      rescue StandardError => e
        { ruby_only: [{ field: "crash", detail: "#{e.class}: #{e.message}" }] }
      end

      def finding(seed, mode, divergences, sequence, match)
        return nil if divergences.empty?

        signature = Shrinker.signature(divergences)
        return nil if match && !(match["mode"] == mode.to_s && Set.new(match["signature"]).subset?(signature))

        { "seed" => seed, "mode" => mode.to_s, "signature" => signature.to_a.sort, "steps" => sequence,
          "divergences" => JSON.parse(JSON.generate(divergences)) }
      end

      # The step-level half of shrinking; the parent already made the domain as small as it could.
      def shrink(domain_path, found, binary, differ, budget)
        original = Set.new(found["signature"])
        mode = found["mode"].to_sym
        Shrinker.call(found["steps"], budget: budget) do |candidate|
          divergences = outcomes(domain_path, candidate, binary, differ)[mode] || []
          Shrinker.reproduces?(original, divergences)
        end.steps
      end
    end
  end
end
