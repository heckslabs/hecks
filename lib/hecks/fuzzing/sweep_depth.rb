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
    end
  end
end
