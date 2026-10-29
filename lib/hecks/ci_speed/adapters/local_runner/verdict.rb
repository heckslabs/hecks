# frozen_string_literal: true

module Hecks
  module Adapters
    class LocalRunner
      # What the samples of the two sides say. A side's time is the median of its samples, which one
      # slow sample from a busy machine does not move. The spread is the larger of the two sides'
      # own range, so the saving has to stand out from how much either side varied by itself.
      class Verdict
        # @return [Float] the base side's median seconds
        attr_reader :base_seconds

        # @return [Float] the candidate side's median seconds
        attr_reader :candidate_seconds

        # @return [Float] the larger of the two sides' ranges, in seconds
        attr_reader :spread_seconds

        # @param base [Array<Float>] the base side's samples, in seconds
        # @param candidate [Array<Float>] the candidate side's samples, in seconds
        def initialize(base:, candidate:)
          @base = base
          @candidate = candidate
          @base_seconds = median(base).round(3)
          @candidate_seconds = median(candidate).round(3)
          @spread_seconds = [range(base), range(candidate)].max.round(3)
        end

        # @return [Float] the base time less the candidate time: negative for a slower candidate
        def saved_seconds = (base_seconds - candidate_seconds).round(3)

        # @return [String] `faster` or `slower` when the saving is larger than the spread, else
        #   `inconclusive`
        def verdict
          return "faster" if saved_seconds > spread_seconds
          return "slower" if (saved_seconds + spread_seconds).negative?

          "inconclusive"
        end

        # @return [Integer] what a lever is told it is worth: the saving in whole seconds when
        #   conclusively faster, else zero
        def expected_seconds = verdict == "faster" ? saved_seconds.round : 0

        # @param definition [String] the definition's name
        # @param refs [Hash{Symbol => String}] each side's ref as the experiment named it
        # @param load [Float] the machine's one-minute load average at the start
        # @return [String] one sentence saying what the numbers rest on
        def basis(definition:, refs:, load:)
          "#{definition} on this machine at load #{load.round(2)}, samples interleaved: " \
            "base #{refs.fetch(:base)} took #{show(@base)}, candidate #{refs.fetch(:candidate)} took #{show(@candidate)}; " \
            "the saving of #{saved_seconds}s against a spread of #{spread_seconds}s is #{verdict}"
        end

        private

        def show(samples)
          "#{median(samples).round(3)}s median (#{samples.map { |sample| sample.round(3) }.join(", ")})"
        end

        def median(samples)
          sorted = samples.sort
          middle = sorted.size / 2
          sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
        end

        def range(samples) = samples.max - samples.min
      end
    end
  end
end
