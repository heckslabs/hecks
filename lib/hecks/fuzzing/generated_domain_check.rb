require "json"
require_relative "isolated_boot"
require_relative "sequence_generator"
require_relative "replay"
require_relative "shrinker"
require_relative "differential"

module Hecks
  module Fuzzing
    # ONE GENERATED DOMAIN, CHECKED — the child-process half of
    # `bin/qa_generated_domains` (one domain per process: every generated
    # domain is named `QaGenerated`, see DomainGenerator's header).
    #
    # The same comparisons `bin/qa_sweep` runs on a rotation target, over
    # sequences generated against a domain nobody wrote: with a compiled
    # binary, `Differential.diff` (Ruby vs Rust, self-consistency, declared
    # properties); without one, a Ruby-only replay (properties,
    # self-consistency, an interpreter crash). A domain that does not even
    # boot is `invalid` — a generator defect, not a finding, reported apart.
    #
    # `match:` is how DOMAIN-level shrinking asks "does this smaller domain
    # still show the same finding?": only a divergence in the same mode
    # whose `Shrinker.signature` contains the original's counts. Verb names
    # survive a removal that did not touch them, so the signature does too.
    module GeneratedDomainCheck
      DIFFERENTIAL_MODES = %i[differential self_consistency properties_in_differential].freeze

      module_function

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
        IsolatedBoot.call(domain_path) { |copy| Hecks.boot(copy) }
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

      # The step-level half of shrinking, in this same process: the domain
      # is already as small as the parent could make it.
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
