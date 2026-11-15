# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # The zone the board counts its days in: Arizona time, an offset of seven hours behind UTC that
      # never changes for daylight saving. A day on the board begins at midnight there, not at
      # midnight UTC (five in the afternoon in Arizona).
      module Zone
        # Arizona's offset from UTC, all year.
        OFFSET = "-07:00"

        module_function

        # @param time [Time] a moment in any zone
        # @return [Time] the same moment in Arizona time
        def at(time) = time.getlocal(OFFSET)

        # @param time [Time, String] a moment in any zone, or its ISO 8601 text
        # @return [Date] the Arizona calendar day it falls on
        def day(time) = at(time.is_a?(String) ? Time.parse(time) : time).to_date
      end
    end
  end
end
