# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Says that the descriptor table is full, at most once in a stretch of seconds, so a loop
      # that meets the condition on every pass writes one line, not thousands.
      class FullLog
        # Seconds between two lines.
        EVERY = 5

        # @param clock [#call] answers a time in seconds
        # @param log [#call] takes one message
        def initialize(clock:, log:)
          @clock = clock
          @log = log
          @last = nil
        end

        # Logs the full table unless a line went out within the interval.
        # @param error [SystemCallError] what accept raised
        # @return [void]
        def say(error)
          now = @clock.call
          return if @last && now - @last < EVERY

          @last = now
          @log.call("PipelineBoard descriptor table full (#{error.class}); shedding connections")
        end
      end
    end
  end
end
