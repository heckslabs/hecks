module Hecks
  module Runtime
    class PolicyInterpreter
      # Times each policy delivery with a clock the interpreter is given, and keeps the timings
      # beside the reaction log, never in a reaction record, which the Rust kernel writes in the
      # same shape. Mixed into {PolicyInterpreter}.
      module Timing
        # The clock a delivery is timed with, in seconds.
        MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

        # The most timings kept before the oldest are dropped.
        LIMIT = 1000

        # Names the slowest delivery among `timings`.
        #
        # @param timings [Array<Hash>] `{ policy:, ms: }` per delivery, as {#drain_timings} answers
        # @return [Hash, nil] the entry with the greatest `ms`, nil when nothing was timed
        def self.slowest(timings) = timings.max_by { |timing| timing[:ms] }

        # Hands over the timings noted since the last drain and forgets them.
        #
        # @return [Array<Hash{Symbol => Object}>] `{ policy:, ms: }` per delivery, oldest first
        def drain_timings
          drained = timings.dup
          timings.clear
          drained
        end

        private

        def timings = @timings ||= []

        # Runs the block and notes how long it took under the policy's name, whatever it answers.
        def timed(policy)
          started = @clock.call
          yield
        ensure
          timings << { policy: policy.name, ms: ((@clock.call - started) * 1000).round(1) }
          timings.shift while timings.size > LIMIT
        end
      end
    end
  end
end
