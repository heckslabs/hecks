# frozen_string_literal: true

require "time"
require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # One reading of how long main has been red, from the CI runs: the last green run and the
      # first red run after it. It holds facts only; the `Main red` verdict row decides the tile's
      # state.
      class RedReading
        include TileKit

        # @param runs [Array<Hash>] CI runs of main, oldest first
        # @param now [Time] the time the minutes are measured to
        def initialize(runs, now)
          @runs = runs
          @now = now
        end

        # @return [Integer, nil] the index of the newest green run in the window, or nil
        def green_index = @runs.rindex { |run| run[:conclusion] == "success" }

        # @return [String, nil] the sha of the newest green run in the window
        def last_green = green_index && @runs[green_index][:sha]

        # @return [String, nil] the sha of the first red run after the last green one
        def culprit = first_red&.fetch(:sha)

        # @return [Time, nil] when main went red, nil when no green run in the window starts it
        def since = first_red && finished(first_red)

        # @return [Integer, nil] the whole minutes main has been red, nil when {#since} is unknown
        def minutes = since && [((@now - since) / 60).to_i, 0].max

        # @return [String] the reading in one line, for the tile's detail
        def words
          parts = [("red since #{since.utc.iso8601} (#{minutes} min)" if since), ("culprit #{culprit}" if culprit),
                   last_green ? "last green #{last_green}" : "no green run in the window"]
          parts.compact.join(", ")
        end

        private

        def first_red
          index = green_index
          index && @runs[index + 1]
        end
      end
    end
  end
end
