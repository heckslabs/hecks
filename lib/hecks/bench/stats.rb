module Hecks
  module Bench
    # Order statistics over latency samples.
    # Percentiles are nearest-rank, never interpolated, so every figure is a latency that happened.
    module Stats
      module_function

      def percentile(samples, fraction)
        return nil if samples.empty?

        sorted = samples.sort
        sorted[[(fraction * sorted.size).ceil - 1, 0].max]
      end

      def median(values)
        return nil if values.empty?

        sorted = values.sort
        middle = sorted.size / 2
        sorted.size.odd? ? sorted[middle].to_f : (sorted[middle - 1] + sorted[middle]) / 2.0
      end

      def latency(seconds)
        {
          count:   seconds.size,
          p50_us:  micros(percentile(seconds, 0.50)),
          p99_us:  micros(percentile(seconds, 0.99)),
          mean_us: micros(seconds.sum / seconds.size),
          max_us:  micros(seconds.max)
        }
      end

      # A ratio well above 1.0 means latency grows as the store fills, which a whole-run p50 hides.
      def drift(seconds)
        tenth = seconds.size / 10
        return nil if tenth.zero?

        (percentile(seconds.last(tenth), 0.5) / percentile(seconds.first(tenth), 0.5)).round(2)
      end

      def micros(seconds)
        seconds && (seconds * 1_000_000).round(1)
      end
    end
  end
end
