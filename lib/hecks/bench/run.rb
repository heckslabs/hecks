module Hecks
  module Bench
    # The raw timings of one measured pass over a workload on one runtime.
    #
    # Runners produce these and know nothing about reporting. {#summary} is the only
    # place raw samples become the figures a report prints.
    class Run
      # @return [Array<Array(String, Float)>] each timed command's verb and latency in
      #   seconds, in dispatch order
      attr_reader :samples

      # @return [Float] seconds from the first timed command's start to the last one's end
      attr_reader :wall_seconds

      # @return [Hash{Symbol => Object}] facts a runner wants reported alongside the timings
      attr_reader :extras

      # Builds a run.
      #
      # @param samples [Array<Array(String, Float)>] verb and latency seconds per command
      # @param wall_seconds [Float] the wall-clock duration of the whole timed pass
      # @param extras [Hash{Symbol => Object}] runner-specific facts, such as a round-trip floor
      def initialize(samples:, wall_seconds:, extras: {})
        @samples = samples
        @wall_seconds = wall_seconds
        @extras = extras
      end

      # Reduces the samples to the figures a report prints.
      #
      # @return [Hash{Symbol => Object}] `:commands`, `:wall_seconds`, `:throughput_per_s`,
      #   the `Stats.latency` figures, `:drift`, `:by_verb` (each verb's count, p50 and p99),
      #   and any `extras`
      def summary
        seconds = samples.map(&:last)
        {
          commands:         samples.size,
          wall_seconds:     wall_seconds.round(4),
          throughput_per_s: (samples.size / wall_seconds).round(1),
          **Stats.latency(seconds),
          drift:            Stats.drift(seconds),
          by_verb:          by_verb
        }.merge(extras)
      end

      private

      def by_verb
        samples.group_by(&:first).transform_values do |group|
          Stats.latency(group.map(&:last)).slice(:count, :p50_us, :p99_us)
        end
      end
    end
  end
end
