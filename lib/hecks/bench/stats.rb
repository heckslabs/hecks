module Hecks
  module Bench
    # Order statistics over a list of latency samples.
    #
    # Percentiles use the nearest-rank method: the smallest sample with at least
    # that fraction of the samples at or below it. It never interpolates, so every
    # reported figure is a latency that actually happened. With fewer than 100
    # samples the p99 is simply the maximum.
    module Stats
      module_function

      # Reads one percentile from a list of samples.
      #
      # @param samples [Array<Float>] the samples, in any order
      # @param fraction [Float] the percentile as a fraction, e.g. `0.99`
      # @return [Float, nil] the nearest-rank percentile, or nil when `samples` is empty
      def percentile(samples, fraction)
        return nil if samples.empty?

        sorted = samples.sort
        sorted[[(fraction * sorted.size).ceil - 1, 0].max]
      end

      # Finds the middle value of a list, averaging the two middle values of an even one.
      #
      # @param values [Array<Numeric>] the values, in any order
      # @return [Float, nil] the median, or nil when `values` is empty
      def median(values)
        return nil if values.empty?

        sorted = values.sort
        middle = sorted.size / 2
        sorted.size.odd? ? sorted[middle].to_f : (sorted[middle - 1] + sorted[middle]) / 2.0
      end

      # Summarizes one run's latency samples.
      #
      # @param seconds [Array<Float>] per-command latencies in seconds, in dispatch order
      # @return [Hash{Symbol => Numeric}] `:count`, and `:p50_us`, `:p99_us`, `:mean_us` and
      #   `:max_us` in microseconds
      def latency(seconds)
        {
          count:   seconds.size,
          p50_us:  micros(percentile(seconds, 0.50)),
          p99_us:  micros(percentile(seconds, 0.99)),
          mean_us: micros(seconds.sum / seconds.size),
          max_us:  micros(seconds.max)
        }
      end

      # Compares how slow the last tenth of a run was against its first tenth.
      #
      # A ratio well above 1.0 means latency grows as the store fills, which a single
      # p50 over the whole run would hide.
      #
      # @param seconds [Array<Float>] per-command latencies in dispatch order
      # @return [Float, nil] the last tenth's p50 over the first tenth's, or nil when there
      #   are fewer than ten samples
      def drift(seconds)
        tenth = seconds.size / 10
        return nil if tenth.zero?

        (percentile(seconds.last(tenth), 0.5) / percentile(seconds.first(tenth), 0.5)).round(2)
      end

      # Converts seconds to microseconds, rounded to a tenth.
      #
      # @param seconds [Float, nil] a duration in seconds
      # @return [Float, nil] the duration in microseconds, or nil when `seconds` is nil
      def micros(seconds)
        seconds && (seconds * 1_000_000).round(1)
      end
    end
  end
end
