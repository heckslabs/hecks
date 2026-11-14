# frozen_string_literal: true

module Hecks
  module Adapters
    class Ticking
      # How long the chain of ticks waits before its next tick: the quick period for the first
      # `quick_for` seconds after boarding (the checks are starting), then each step of the ladder
      # in turn, the last one for good. It reads time as numbers and holds no clock.
      class Backoff
        # Seconds the quick period lasts when the world names none.
        QUICK_FOR = 60

        # Seconds between ticks after the quick period, one step per tick, the last one repeating.
        STEPS = [60, 120, 240].freeze

        # @return [Float] seconds between ticks while the quick period lasts
        attr_reader :quick

        # @return [Array<Float>] the steps after the quick period
        attr_reader :steps

        # @param quick [Numeric] seconds between ticks in the quick period
        # @param quick_for [Numeric] seconds the quick period lasts
        # @param steps [Array<Numeric>] the ladder after it
        def initialize(quick:, quick_for: QUICK_FOR, steps: STEPS)
          @quick = quick.to_f
          @quick_for = quick_for.to_f
          @steps = (steps.empty? ? STEPS : steps).map(&:to_f)
        end

        # @param text [String, nil] `quick,quick_for,step,...` as the adapter hands it to a child
        # @return [Backoff]
        def self.parse(text)
          quick, quick_for, *steps = text.to_s.split(",").map(&:to_f)
          new(quick: quick || 0, quick_for: quick_for || QUICK_FOR, steps: steps)
        end

        # @return [String] the form {.parse} reads
        def to_s = [@quick, @quick_for, *@steps].join(",")

        # @param elapsed [Numeric] seconds since the chain began
        # @return [Boolean] whether the quick period still lasts
        def quick?(elapsed) = elapsed < @quick_for

        # @param elapsed [Numeric] seconds since the chain began
        # @param slow [Integer] how many ticks have already been waited for after the quick period
        # @return [Float] seconds to wait before the next tick
        def delay(elapsed, slow)
          return @quick if quick?(elapsed)

          @steps[[slow, @steps.size - 1].min]
        end

        # @return [Float] the longest wait: the safety tick a watcher may not hide a merge past
        def cap = @steps.last

        # @param minutes [Numeric] how long a chain may run
        # @return [Integer] how many ticks the schedule makes in them (the bluebook's beat limit)
        def limit(minutes)
          elapsed = 0.0
          (1..).each do |count|
            elapsed += delay(elapsed, [count - 1 - quick_ticks, 0].max).clamp(1, Float::INFINITY)
            return count - 1 if elapsed > minutes * 60
          end
        end

        private

        def quick_ticks = (@quick_for / [@quick, 1].max).ceil
      end
    end
  end
end
