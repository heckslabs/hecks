# frozen_string_literal: true

require "json"

module Hecks
  module QualityControlCli
    class QaRoundTrip
      # Scores another run of the benchmark's scripts against the reference, step by step: whether
      # each step was accepted, the events it caused and the rows a query answered, then each
      # script's final state. Refusal wording is never compared; the protocol does not print it.
      class Comparison
        # The ways one step can disagree, in the order a report lists them.
        STEP_KINDS = %w[accepted_vs_refused refused_vs_accepted events rows].freeze

        # How many disagreements of a kind a report quotes.
        EXAMPLES = 5

        def initialize
          @tally = Hash.new(0)
          @examples = Hash.new { |hash, kind| hash[kind] = [] }
        end

        # Compares one script's two runs and adds them to the tally.
        #
        # @param label [String] names the script in the report
        # @param reference [Array<Hash>] the reference's lines, `"step"` lines then a `"state"` line
        # @param other [Array<Hash>] the other run's lines
        # @return [void]
        def add(label, reference, other)
          ref_steps, other_steps = [reference, other].map { |lines| lines.select { |line| line.key?("step") } }
          @tally["length_mismatch"] += 1 unless ref_steps.size == other_steps.size
          ref_steps.zip(other_steps).each { |expected, actual| add_step(label, expected, actual || {}) }
          @tally[same_state?(reference, other) ? "final_state_agree" : "final_state_differs"] += 1
        end

        # Whether every step and every final state agreed.
        #
        # @return [Boolean] true when nothing disagreed
        def agree?
          (STEP_KINDS + %w[final_state_differs length_mismatch]).all? { |kind| @tally[kind].zero? }
        end

        # The tally, then a few examples of each kind of disagreement.
        #
        # @return [String] the report, one line per count and per example
        def report
          counts = @tally.sort.map { |kind, count| "#{kind}: #{count}" }
          examples = @examples.flat_map { |kind, lines| ["-- #{kind}", *lines.map { |line| "   #{line}" }] }
          (counts + examples).join("\n")
        end

        private

        def add_step(label, expected, actual)
          @tally["steps"] += 1
          kind = disagreement(expected, actual)
          return @tally["agree"] += 1 unless kind

          @tally[kind] += 1
          return unless @examples[kind].size < EXAMPLES

          @examples[kind] << "#{label} step #{expected["step"]}: #{brief(expected)} vs #{brief(actual)}"
        end

        def disagreement(expected, actual)
          return expected["ok"] ? "accepted_vs_refused" : "refused_vs_accepted" unless expected["ok"] == actual["ok"]
          return "events" unless expected["events"] == actual["events"]

          "rows" if expected.key?("rows") && canonical(expected["rows"]) != canonical(actual["rows"])
        end

        def same_state?(reference, other)
          [reference, other].map { |lines| canonical_state(lines.find { |line| line.key?("state") }) }.uniq.size == 1
        end

        def canonical_state(line)
          (line || {}).fetch("state", {}).transform_values { |records| records.map { |r| JSON.generate(sorted(r)) }.sort }
        end

        def canonical(rows) = Array(rows).map { |row| JSON.generate(sorted(row)) }

        def sorted(value)
          case value
          when Hash then value.sort.to_h { |k, v| [k, sorted(v)] }
          when Array then value.map { |element| sorted(element) }
          else value
          end
        end

        def brief(line) = JSON.generate(line.except("step"))[0, 120]
      end
    end
  end
end
