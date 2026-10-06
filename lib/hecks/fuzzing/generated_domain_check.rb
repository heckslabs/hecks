require "json"
require_relative "isolated_boot"
require_relative "sequence_generator"
require_relative "replay"
require_relative "shrinker"
require_relative "differential"

module Hecks
  module Fuzzing
    # The child-process half of `hecks quality_control target.check_generated_domains`: checks one
    # generated domain.
    #
    # One domain per process, since every generated domain is named `QaGenerated`.
    # A domain that fails to boot is `invalid` (a generator defect), not a finding.
    module GeneratedDomainCheck
      DIFFERENTIAL_MODES = %i[differential self_consistency properties_in_differential].freeze

      # What one check run is configured with beyond the domain and seed count.
      Settings = Struct.new(:steps, :adversarial, :binary, :differ, :match, :shrink_budget, keyword_init: true)

      module_function

      # Checks one generated domain over up to `seeds` sequences, stopping at the first finding.
      #
      # With a compiled `binary` it diffs Ruby against Rust; without one it replays Ruby only.
      # `match` (`{"mode" =>, "signature" =>}`) keeps only a finding that still matches, so
      # domain-level shrinking can ask whether a smaller domain shows the same finding.
      #
      # Beyond the required keywords it takes `binary:`, `differ:`, `match:` (default nil) and
      # `shrink_budget:` (default 0).
      #
      # @return [Hash] `"status"` is `"invalid"`, `"clean"` or `"found"`; a found finding is
      #   `#finding` merged with `"seeds_run"`, plus `"shrunk_steps"` if `shrink_budget` > 0
      def run(domain_path, seeds:, steps:, adversarial:, **)
        settings = Settings.new(shrink_budget: 0, steps: steps, adversarial: adversarial, **)
        error = boot_error(domain_path)
        return { "status" => "invalid", "error" => error } if error

        (1..seeds).each do |seed|
          finding = check_seed(domain_path, seed, settings)
          return found(domain_path, finding, settings, seed) if finding
        end
        { "status" => "clean", "seeds_run" => seeds }
      end

      def found(domain_path, finding, settings, seed)
        if settings.shrink_budget.positive?
          finding["shrunk_steps"] = shrink(domain_path, finding, settings.binary, settings.differ, settings.shrink_budget)
        end
        finding.merge("status" => "found", "seeds_run" => seed)
      end

      def boot_error(domain_path)
        IsolatedBoot.call(domain_path) { |copy| Hecks.boot(copy, environment: nil) }
        nil
      rescue StandardError, ScriptError => e
        "#{e.class}: #{e.message.lines.first&.strip}"
      end

      def check_seed(domain_path, seed, settings)
        sequence = SequenceGenerator.generate(domain_path, seed: seed, steps: settings.steps,
                                                           adversarial: settings.adversarial)
      rescue StandardError => e
        finding(seed, :generator, [{ field: "generator_crash", detail: "#{e.class}: #{e.message}" }], [], settings.match)
      else
        outcomes(domain_path, sequence, settings.binary, settings.differ).each do |mode, divergences|
          found = finding(seed, mode, divergences, sequence, settings.match)
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
