module Hecks
  module Fuzzing
    # Maps a QA target's clean streak to how hard the next sweep fuzzes.
    module SweepDepth
      module_function

      # Fallback tiers for a ledger with no QualityControlDials configured.
      DEFAULT_TIERS = [
        { upto: 4,               seeds: 10, steps: 25 },
        { upto: 19,              seeds: 25, steps: 50 },
        { upto: Float::INFINITY, seeds: 50, steps: 100 }
      ].freeze

      # Rows are read in order; the last row must keep upto: Float::INFINITY.
      def for_streak(streak, tiers: DEFAULT_TIERS)
        raise ArgumentError, "streak must not be negative" if streak.negative?

        tier = tiers.find { |row| streak <= row[:upto] }
        raise ArgumentError, "no tier covers a streak of #{streak} — the last row must be upto: Float::INFINITY" unless tier

        [tier[:seeds], tier[:steps]]
      end

      # The first seed a streak-widened sweep counts from. Once a target's streak has widened past
      # the ceiling tier, `for_streak` keeps returning the same seed count forever; sweeping
      # `1..seeds` every time would regenerate the identical sequences on every tick. Advancing
      # this with the streak keeps the swept range moving into seed integers no earlier tick of
      # this streak ever reached, without a new persisted field: `streak` already ties consecutive
      # tiers' ranges back to back (each tier's width times its own streak count), and a streak
      # reset (back to 0) lands this back at 0 too, so a fresh or just-released target still sweeps
      # the familiar `1..seeds`.
      #
      # @param streak [Integer] `Target#clean_streak`, non-negative
      # @param seeds [Integer] the seed count `for_streak` resolved for this same streak
      # @return [Integer] the offset; the sweep should cover `(offset + 1)..(offset + seeds)`
      def seed_offset(streak, seeds)
        raise ArgumentError, "streak must not be negative" if streak.negative?

        streak * seeds
      end
    end
  end
end
