require "json"
require_relative "isolated_boot"
require_relative "sequence_generator"
require_relative "replay"
require_relative "shrinker"
require_relative "differential"

module Hecks
  module Fuzzing
    # **One generated domain, checked** — the child-process half of
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
    # `match:` is how domain-level shrinking asks "does this smaller domain
    # still show the same finding?": only a divergence in the same mode
    # whose `Shrinker.signature` contains the original's counts. Verb names
    # survive a removal that did not touch them, so the signature does too.
    module GeneratedDomainCheck
      DIFFERENTIAL_MODES = %i[differential self_consistency properties_in_differential].freeze

      module_function

      # Checks one generated domain over up to `seeds` generated sequences, stopping
      # at the first divergence found.
      #
      # @param domain_path [String] path to the generated domain directory
      # @param seeds [Integer] maximum number of seeds to try before declaring clean
      # @param steps [Integer] steps to generate per seed
      # @param adversarial [Float] fraction of command steps to mutate adversarially
      # @param binary [String, nil] path to a compiled Rust conformance binary to
      #   diff against, or `nil` for a Ruby-only check
      # @param differ [Object, nil] duck-typed comparison helper answering
      #   `RustConformanceHelpers`' interface (adapter-defined; constructed ad hoc
      #   by callers such as bin/qa_generated_domains), or `nil`
      # @param match [Hash, nil] `{"mode" =>, "signature" =>}` from a parent
      #   domain's own finding — only a divergence matching it counts, for
      #   domain-level shrinking; `nil` accepts the first divergence found
      # @param shrink_budget [Integer] step-level shrink attempts to spend on a
      #   found finding; `0` skips shrinking
      # @return [Hash] `{"status" => "invalid", "error" =>}` if the domain does not
      #   boot; `{"status" => "clean", "seeds_run" =>}` if no seed diverged;
      #   otherwise a finding merged with `{"status" => "found", "seeds_run" =>}`
      #   (see `#finding`), plus `"shrunk_steps"` when `shrink_budget` is positive
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

      # Boots `domain_path` in an isolated copy, to find out whether it boots at all.
      #
      # @param domain_path [String] path to the domain directory to boot
      # @return [String, nil] `nil` if the boot succeeds; otherwise the raising
      #   exception's class and first message line
      def boot_error(domain_path)
        IsolatedBoot.call(domain_path) { |copy| Hecks.boot(copy) }
        nil
      rescue StandardError, ScriptError => e
        "#{e.class}: #{e.message.lines.first&.strip}"
      end

      # Generates one sequence for `seed` and checks it for a divergence.
      #
      # @param domain_path [String] path to the domain directory
      # @param seed [Integer] RNG seed for `SequenceGenerator.generate`
      # @param steps [Integer] steps to generate
      # @param adversarial [Float] fraction of command steps to mutate adversarially
      # @param binary [String, nil] path to a compiled Rust conformance binary, or
      #   `nil` for a Ruby-only check
      # @param differ [Object, nil] duck-typed comparison helper answering
      #   `RustConformanceHelpers`' interface (adapter-defined), or `nil`
      # @param match [Hash, nil] `{"mode" =>, "signature" =>}` a divergence must
      #   match to count, or `nil` to accept the first one found
      # @return [Hash, nil] a finding (see `#finding`) if a matching divergence was
      #   found, or if generation itself crashed; `nil` if the sequence was clean
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

      # Runs the comparison appropriate to whether a compiled binary is available:
      # `Differential.diff` against Rust when `binary` is given, otherwise a
      # Ruby-only replay checked for property and self-consistency divergences.
      #
      # @param domain_path [String] path to the domain directory
      # @param sequence [Array<Hash>] the generated step sequence to replay
      # @param binary [String, nil] path to a compiled Rust conformance binary, or
      #   `nil` for a Ruby-only check
      # @param differ [Object, nil] duck-typed comparison helper answering
      #   `RustConformanceHelpers`' interface (adapter-defined), or `nil`
      # @return [Hash{Symbol => Array<Hash>}] one divergence list per mode checked;
      #   `{ruby_only: [{field: "crash", detail:}]}` if the Ruby-only replay itself
      #   raised
      def outcomes(domain_path, sequence, binary, differ)
        return Differential.diff(differ, domain_path, sequence, binary, modes: DIFFERENTIAL_MODES) if binary

        history = Replay.call(domain_path, sequence, self_consistency: true)
        { ruby_only:        Differential.property_divergences(history),
          self_consistency: Differential.self_consistency_divergences(history) }
      rescue StandardError => e
        { ruby_only: [{ field: "crash", detail: "#{e.class}: #{e.message}" }] }
      end

      # Builds a reported finding from a mode's divergences, unless `divergences`
      # is empty or `match` names a different signature.
      #
      # @param seed [Integer] the seed that produced `sequence`
      # @param mode [Symbol] the comparison mode the divergences came from
      # @param divergences [Array<Hash>] divergence entries for `mode`
      # @param sequence [Array<Hash>] the generated step sequence
      # @param match [Hash, nil] `{"mode" =>, "signature" =>}` the finding must
      #   match, or `nil` to accept any
      # @return [Hash, nil] `{"seed" =>, "mode" =>, "signature" =>, "steps" =>,
      #   "divergences" =>}` if `divergences` is non-empty and matches `match`;
      #   `nil` otherwise
      def finding(seed, mode, divergences, sequence, match)
        return nil if divergences.empty?

        signature = Shrinker.signature(divergences)
        return nil if match && !(match["mode"] == mode.to_s && Set.new(match["signature"]).subset?(signature))

        { "seed" => seed, "mode" => mode.to_s, "signature" => signature.to_a.sort, "steps" => sequence,
          "divergences" => JSON.parse(JSON.generate(divergences)) }
      end

      # The step-level half of shrinking, in this same process: the domain
      # is already as small as the parent could make it.
      #
      # @param domain_path [String] path to the (already domain-shrunk) domain
      #   directory
      # @param found [Hash] the finding to shrink, as returned by `#finding`
      # @param binary [String, nil] path to a compiled Rust conformance binary, or
      #   `nil` for a Ruby-only check
      # @param differ [Object, nil] duck-typed comparison helper answering
      #   `RustConformanceHelpers`' interface (adapter-defined), or `nil`
      # @param budget [Integer] step-level shrink attempts to spend
      # @return [Array<Hash>] the smallest step list found that still reproduces
      #   `found`'s divergence signature
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
