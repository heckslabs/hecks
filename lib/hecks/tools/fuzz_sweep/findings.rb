# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module FuzzSweep
      # Replays a generated sequence and judges, groups and shrinks what it finds.
      module Findings
        # An exception escaping Replay's per-step isolation is an interpreter defect, not a domain
        # refusal.
        #
        # @param domain [String] the domain directory
        # @param steps [Array<Hash>] the sequence to replay
        # @param adapter [Symbol] the persistence to boot on
        # @return [Array(Symbol, String)] the verdict (`:clean`, `:property_violation`,
        #   `:crash`) and its message
        def outcome(domain, steps, adapter = :memory)
          history = Hecks::Fuzzing::Replay.call(domain, steps, adapter: adapter)
          violations = Hecks::Fuzzing::Properties.check(history).reject { |_, result| result == true }
          return [:clean, nil] if violations.empty?

          [:property_violation, violations.map { |name, message| "#{name}: #{message}" }.join("; ")]
        rescue StandardError => e
          [:crash, "#{e.class}: #{e.message}"]
        end

        # Groups findings by property name or exception class, stable across shrink candidates.
        #
        # @param message [String, nil] a finding's message
        # @return [String] the property name or exception class it opens with
        def signature_of(message)
          return "unknown" unless message

          message.split(":").first
        end

        # A compound finding that mixes a known shape with any other offender is not known and still
        # fails.
        #
        # @param name [String] the domain's name
        # @param failure [Hash] a finding: `signature` and `message`
        # @return [Boolean] whether every offender is an allowlisted one
        def known_finding?(name, failure)
          matchers = KNOWN_FUZZ_FINDINGS.dig(name, failure[:signature])
          return false unless matchers

          failure[:message].split("; ").all? { |chunk| matchers.any? { |regex| regex.match?(chunk) } }
        end

        # Skips only exact, already-tracked wiring gaps; any other WiringError is re-raised.
        #
        # @param error [Hecks::Runtime::WiringError] what generating a sequence raised
        # @return [Symbol] a key of `SKIPPED_DOMAIN_REASONS`
        def known_unfuzzable_wiring_gap(error)
          case error.message
          when %r{a compute/rekey rule is declared}
            # compute/rekey needs an era/Postgres migration, so it cannot boot under IsolatedBoot's
            # Memory rebind. Real coverage lives in spec/adapters/driven/postgres_era/*_spec.rb.
            :skip_compute_rekey
          else
            raise error
          end
        end

        # Shrinks steps, then arguments, keeping a removal only while the same finding reproduces.
        #
        # @param domain [String] the domain directory
        # @param steps [Array<Hash>] the failing sequence
        # @param signature [String] the finding to keep
        # @param adapter [Symbol] the persistence to boot on
        # @return [Array<Hash>] the smallest sequence found
        def shrink(domain, steps, signature, adapter = :memory)
          Hecks::Fuzzing::Shrinker.call(steps) { |candidate| same_finding?(domain, candidate, signature, adapter) }.steps
        end

        # @param domain [String] the domain directory
        # @param candidate [Array<Hash>] a sequence to replay
        # @param signature [String] the finding to keep
        # @param adapter [Symbol] the persistence to boot on
        # @return [Boolean] whether the candidate sequence reproduces the finding
        def same_finding?(domain, candidate, signature, adapter)
          verdict, message = outcome(domain, candidate, adapter)
          "#{verdict}: #{signature_of(message)}" == signature
        end

        # @param step [Hash] one step of a sequence
        # @return [Hash] its arguments
        def args_of(step) = Hecks::Fuzzing::Shrinker.args_of(step)

        # The argument pass alone.
        #
        # @param domain [String] the domain directory
        # @param steps [Array<Hash>] the failing sequence
        # @param signature [String] the finding to keep
        # @param adapter [Symbol] the persistence to boot on
        # @return [Array<Hash>] the sequence with every argument the finding does not need dropped
        def shrink_arguments(domain, steps, signature, adapter = :memory)
          Hecks::Fuzzing::Shrinker.drop_arguments(steps, Hecks::Fuzzing::Shrinker::Meter.new(nil)) do |candidate|
            same_finding?(domain, candidate, signature, adapter)
          end
        end
      end
    end
  end
end
