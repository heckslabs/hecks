# frozen_string_literal: true

module Hecks
  module Fuzzing
    class SequenceGenerator
      # The clock a generated sequence reads its `needs` facts from (ADR 0081), owned by the seed so
      # neither engine's wall clock decides a step. It starts at an instant drawn from the seed with
      # a `Random` of its own, never the generator's, so a pinned seed's draws are unchanged, and it
      # moves forward by `TICK` seconds a reading.
      #
      # The answer rides in the step's own arguments, where the runtime would put it, so a step
      # replays on either engine with today's corpus readers.
      class SeededClock
        # 2023-11-14T22:13:20Z, the earliest instant a seed can start at.
        EPOCH = 1_700_000_000

        # One year: the spread of start instants across seeds.
        SPAN = 31_536_000

        # Seconds the clock moves forward a reading.
        TICK = 60

        # Seconds in a day, as `Runtime::Needs` answers `today`.
        DAY = 86_400

        # @param seed [Integer] the generator's seed
        def initialize(seed)
          @now = EPOCH + Random.new(seed).rand(SPAN)
        end

        # @return [Integer] the next reading, in Unix epoch seconds
        def now = @now += TICK

        # @param fact [String, Symbol] a fact `Runtime::Needs::ANSWERS` names (`now` or `today`)
        # @return [Integer] its answer: the reading, or the whole days since the epoch
        def answer(fact) = fact.to_s == "today" ? now / DAY : now
      end
    end
  end
end
