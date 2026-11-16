# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Which failed-job logs the board has just failed to read, so a slow or refused read is not
      # repeated on every refresh. A job whose read failed is held for a back-off: 10 minutes
      # after the first failure, doubling with each consecutive one, to an hour at most. A read
      # that then succeeds clears the job. An entry long past its hold is dropped the next time
      # the table is touched, so it holds only the jobs failing lately. Gather threads share it,
      # so it is guarded.
      class LogBackoff
        # Seconds a job is held after its first failed read.
        FIRST_SECONDS = 600

        # Seconds a job is held at most, and how long past its hold a failure is remembered.
        LONGEST_SECONDS = 3600

        # @param settings [Hash] a reader's settings; `clock:` stands in for the monotonic clock
        # @return [LogBackoff]
        def self.for(settings) = settings[:clock] ? new(clock: settings[:clock]) : new

        # @param clock [#call] the time in seconds; the monotonic clock when none is given
        def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @clock = clock
          @held = {}
          @lock = Mutex.new
        end

        # @param job [Integer] a job's id
        # @return [Boolean] whether its read failed lately enough that it is not asked again yet
        def held?(job)
          @lock.synchronize do
            release_ended
            @held.key?(job) && @held[job][:until] > @clock.call
          end
        end

        # Records a failed read: the job is held for twice as long as after the failure before it.
        # @param job [Integer] a job's id
        # @return [void]
        def failed!(job)
          @lock.synchronize do
            release_ended
            streak = @held.fetch(job, { streak: 0 })[:streak] + 1
            @held[job] = { streak: streak, until: @clock.call + seconds(streak) }
          end
        end

        # Forgets a job whose read succeeded.
        # @param job [Integer] a job's id
        # @return [void]
        def clear!(job) = @lock.synchronize { @held.delete(job) }

        # @return [Integer] how many jobs are remembered
        def size = @lock.synchronize { @held.size }

        private

        def seconds(streak) = [FIRST_SECONDS * (2**(streak - 1)), LONGEST_SECONDS].min

        def release_ended
          now = @clock.call
          @held.delete_if { |_, entry| entry[:until] + LONGEST_SECONDS <= now }
        end
      end
    end
  end
end
