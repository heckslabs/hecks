module Hecks
  module Fuzzing
    # Weighted pick over `QualityControl::Target.Rotation` rows: staleness blended with yield.
    # Pure: no clock, no queries; `now` is an argument.
    module RotationPriority
      module_function

      # The next stored `Target.yield_score`: decayed old score plus this period's surprises.
      # Integer division, like every other count in the ledger.
      #
      # @param old_score [Integer] the score before this period
      # @param surprises_this_period [Integer] Surprised checks found this period
      # @param decay_percent [Integer] percent of `old_score` that survives
      # @return [Integer] the next score to store
      # @raise [ArgumentError] if either count is negative
      def next_yield_score(old_score:, surprises_this_period:,
                           decay_percent: QualityControlDials::YIELD_DECAY_PERCENT)
        raise ArgumentError, "old_score must not be negative" if old_score.negative?
        raise ArgumentError, "surprises_this_period must not be negative" if surprises_this_period.negative?

        ((old_score * decay_percent) / 100) + surprises_this_period
      end

      # Picks the next target from `Target.Rotation` rows, or nil when there are none.
      #
      # A row stale past `floor_seconds` wins outright (oldest first), so no target starves.
      # Otherwise the highest `staleness + yield_score * weight_seconds` wins.
      #
      # @param rows [Array<Hash>] rows with `:last_swept`, `:yield_score` as `{ value: Integer }`
      # @param now [Integer] current time, Unix epoch seconds
      # @param weight_seconds [Integer] seconds of staleness one yield point is worth
      # @param floor_seconds [Integer] staleness past which a row jumps the queue
      # @return [Hash, nil] the picked row
      def pick(rows, now:, weight_seconds: QualityControlDials::YIELD_WEIGHT_SECONDS,
               floor_seconds: QualityControlDials::ROTATION_STALE_FLOOR_SECONDS)
        return nil if rows.empty?

        floored = rows.select { |row| staleness(row, now) >= floor_seconds }
        return floored.min_by { |row| row[:last_swept][:value] } unless floored.empty?

        rows.max_by { |row| staleness(row, now) + (row[:yield_score][:value] * weight_seconds) }
      end

      def staleness(row, now) = now - row[:last_swept][:value]
      private_class_method :staleness
    end
  end
end
