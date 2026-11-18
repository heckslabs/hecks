# frozen_string_literal: true

require_relative "sentinel/heat"

module Hecks
  module Adapters
    module PipelineBoard
      # A process of its own that watches the board from outside. A board whose threads all wait
      # for the Ruby interpreter lock cannot restart itself, because every thread it could use to
      # notice is stuck too; this process asks the board's page for an answer every `every`
      # seconds, and after `misses` asks in a row with none it stops the board and starts it again
      # as the command that started it. A board that answers but holds a core (see {Heat}) is
      # restarted the same way. It ends when the board's pid stops being its parent.
      class Sentinel
        # @param pid [Integer] the board's process id
        # @param every [Numeric] seconds between asks
        # @param misses [Integer] asks in a row without an answer that count as a stall
        # @param host [#answered?, #cpu_seconds, #clock, #stop, #restart, #pause, #parent_alive?]
        #   the outside: asks the page, reads the board's CPU time and the clock, stops the board,
        #   starts it again, waits, and says whether the board still stands
        # @param heat [Heat] the bound on the board's CPU; none when not given
        def initialize(pid:, every:, misses:, host:, heat: Heat.off)
          @pid = pid
          @every = every
          @misses = misses
          @host = host
          @heat = heat
          @missed = 0
        end

        # Asks until the board is gone or has been restarted.
        # @return [Symbol] `:gone` when the board ended on its own, `:restarted` after a stall or
        #   a run of hot asks
        def run
          while @host.parent_alive?
            @host.pause(@every)
            return :gone unless @host.parent_alive?
            return restarted(@missed, "stall") if stalled?
            return restarted(@heat.count, "cpu") if hot?
          end
          :gone
        end

        private

        def stalled?
          @missed = @host.answered? ? 0 : @missed + 1
          @missed >= @misses
        end

        def hot? = @heat.on? && @heat.hot?(@host.cpu_seconds(@pid), @host.clock)

        def restarted(asks, reason)
          @host.stop(@pid)
          @host.restart(misses: asks, reason: reason)
          :restarted
        end
      end
    end
  end
end
