# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      # One job's wait for a heavy-job place: the arrival time it keeps across retries, and whether
      # its line has stopped moving.
      #
      # The first arrival is written to `HECKS_HEAVY_ARRIVAL` in the environment, so a retry in the
      # same process, a child, or a caller that sets it first takes its ticket at the same place in
      # the line instead of at the back. A value in the future or older than `MAX_AGE` is ignored,
      # and the mark is cleared once the job has held a place.
      #
      # A wait gives up only when the line is stalled: the number of live tickets ahead has not
      # fallen for `bound` seconds. A line that moves never ends a job's wait.
      class SlotWait
        # The environment variable that carries the first arrival, in nanoseconds.
        ARRIVAL = "HECKS_HEAVY_ARRIVAL"

        # Seconds after which a carried arrival is taken as left over and ignored.
        MAX_AGE = 6 * 3600

        # @param base [#[]] the environment, written to as well as read
        # @param clock [#call] answers the time in seconds
        # @param started [Numeric] the clock's time when the wait began
        # @param bound [Numeric] seconds a stalled line is waited on
        def initialize(base, clock, started, bound)
          @base = base
          @clock = clock
          @moved = started
          @bound = bound
        end

        # Takes a ticket in the line.
        #
        # @param dir [String] the directory the places live in
        # @param job [String] the job's class
        # @return [SlotQueue] the joined line
        def join(dir, job)
          SlotQueue.new(dir, priority: SlotQueue.priority_of(@base, job), arrival: method(:arrival)).join
        end

        # @return [Integer] the arrival in nanoseconds: the carried one, else now (then carried)
        def arrival
          now = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
          kept = Integer(@base[ARRIVAL].to_s, exception: false)
          return kept if kept && kept <= now && now - kept <= MAX_AGE * 1_000_000_000

          @base[ARRIVAL] = now.to_s
          now
        end

        # Forgets the carried arrival.
        #
        # @return [void]
        def release
          @base.delete(ARRIVAL)
        end

        # @param queue [SlotQueue] the waiter's place in the line
        # @return [Boolean] whether the tickets ahead have not fallen in number for `bound` seconds
        def stalled?(queue)
          ahead = queue.ahead
          now = @clock.call
          @moved = now if @ahead && ahead < @ahead
          @ahead = ahead
          now - @moved >= @bound
        end
      end
    end
  end
end
