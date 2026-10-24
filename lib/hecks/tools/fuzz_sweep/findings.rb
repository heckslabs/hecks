# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module FuzzSweep
      # Replays a generated sequence and judges, groups and shrinks what it finds.
      module Findings
        # An exception escaping Replay's per-step isolation is an interpreter defect, not a domain
        # refusal. A sweep on SQLite or Postgres also checks that adapter's projection answers
        # each rooted read model as the in-process loop does (ADR 0121).
        #
        # @param domain [String] the domain directory
        # @param steps [Array<Hash>] the sequence to replay
        # @param adapter [Symbol] the persistence to boot on
        # @return [Array(Symbol, String)] the verdict (`:clean`, `:property_violation`,
        #   `:crash`) and its message
        def outcome(domain, steps, adapter = :memory)
          history = Hecks::Fuzzing::Replay.call(domain, steps, adapter: adapter)
          violations = property_results(domain, steps, adapter, history).reject { |_, result| result == true }
          return [:clean, nil] if violations.empty?

          [:property_violation, violations.map { |name, message| "#{name}: #{message}" }.join("; ")]
        rescue StandardError => e
          [:crash, "#{e.class}: #{e.message}"]
        end

        # The standard battery's results, and the projection agreement's when `adapter` has one.
        #
        # @param domain [String] the domain directory
        # @param steps [Array<Hash>] the sequence replayed
        # @param adapter [Symbol] the persistence it was replayed on
        # @param history [Hash] the replayed history
        # @return [Hash{Symbol => true, String}] each property name mapped to its result
        def property_results(domain, steps, adapter, history)
          results = Hecks::Fuzzing::Properties.check(history)
          agreement = Hecks::Fuzzing::ProjectionAgreement
          return results unless agreement.checks?(adapter)

          results.merge(agreement::PROPERTY => agreement.property(domain, steps, adapter))
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

        # Skips only exact, already-tracked wiring gaps (`SKIPPED_DOMAIN_REASONS`); none is tracked
        # now, so any WiringError is re-raised.
        #
        # @param error [Hecks::Runtime::WiringError] what generating a sequence raised
        # @return [Symbol] a key of `SKIPPED_DOMAIN_REASONS`
        def known_unfuzzable_wiring_gap(error)
          raise error
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
