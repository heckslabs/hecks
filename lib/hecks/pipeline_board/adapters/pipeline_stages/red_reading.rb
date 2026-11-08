# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/red_flag_report"
require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # One reading of how long main has been red, for every place the board says it. A standing
      # red flag is the authority: its minutes come from `RedFlagReport`, as the strip's row and
      # the status query print them. With no flag, the CI runs give the reading: the last green run
      # and the first red run after it. It holds facts only; the `Main red` verdict row decides the
      # tile's state.
      class RedReading
        include TileKit

        # @param runs [Array<Hash>] CI runs of main, oldest first
        # @param flag [Hash, nil] the red flag marker, `{unknown: reason}` or nil
        # @param now [Time] the time the minutes are measured to
        def initialize(runs, flag, now)
          @runs = runs
          @flag = flag.is_a?(Hash) && flag.key?("id") ? flag : nil
          @now = now
        end

        # @return [Boolean] whether a red flag stands
        def flagged? = !@flag.nil?

        # @return [Integer, nil] the index of the newest green run in the window, or nil
        def green_index = @runs.rindex { |run| run[:conclusion] == "success" }

        # @return [String, nil] the sha of the newest green run in the window
        def last_green = green_index && @runs[green_index][:sha]

        # @return [String, nil] the commit main went red at: the flag's, else the first red run's
        def culprit
          return @flag["commit"].to_s[0, 10] if flagged?

          first_red&.fetch(:sha)
        end

        # @return [Time, nil] when main went red, nil when no green run in the window starts it
        def since
          return flag_since if flagged?

          first_red && finished(first_red)
        end

        # @return [Integer, nil] the whole minutes main has been red, nil when {#since} is unknown
        def minutes
          return unless since
          return Hecks::Adapters::RedFlagReport.new(@flag, now: @now).elapsed_seconds / 60 if flagged?

          [((@now - since) / 60).to_i, 0].max
        end

        # @return [String, nil] who is fixing it: the landed fix branch, else the newest check-in
        def fixer
          return unless flagged?
          return "#{@flag["fix_branch"]} at #{@flag["fix_tip"].to_s[0, 10]}" if @flag["fix_branch"]

          helper = @flag["checkins"].to_a.last
          helper && "#{helper["session"]} takes #{helper["taking"]}"
        end

        # @return [String] the reading in one line, for the tile's detail
        def words
          parts = [("red since #{since.utc.iso8601} (#{minutes} min)" if since), ("culprit #{culprit}" if culprit),
                   last_green ? "last green #{last_green}" : "no green run in the window", ("fixer #{fixer}" if fixer)]
          parts.compact.join(", ")
        end

        private

        def first_red
          index = green_index
          index && @runs[index + 1]
        end

        def flag_since
          Time.iso8601(@flag.fetch("raised_at"))
        rescue ArgumentError, KeyError, TypeError
          nil
        end
      end
    end
  end
end
