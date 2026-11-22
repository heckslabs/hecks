# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class PaceReading
      # The count over one window: the event lines inside it, less the noise, and the finished ones.
      class Count
        # @param lines [Array<Hash>] the tap's lines
        # @param window [Hash] the `Window` row (`label`, `seconds`)
        # @param rows [Rows] the noise and finished events
        # @param now [Integer] the clock's now, in epoch seconds
        def initialize(lines, window, rows, now)
          @window = window
          @rows = rows
          @inside = lines.select { |line| line["kind"] == "event" && inside?(line, now) }
        end

        # @return [String] the window, the events counted, and gross, net and efficiency
        def text
          [
            "window: #{@window[:label]}",
            "events: #{generated}",
            "gross: #{per_hour(generated)}/h",
            "net: #{per_hour(finished)}/h",
            "efficiency: #{efficiency}"
          ].join("\n")
        end

        private

        def generated = @inside.count { |line| !@rows.noise.include?(line["event"]) }

        def finished = @inside.count { |line| @rows.finished.include?(line["event"]) }

        def per_hour(count) = (count * 3_600.0 / @window[:seconds]).round(1).then { |n| n == n.to_i ? n.to_i : n }

        def efficiency = generated.zero? ? 0 : (finished * 1000.0 / generated).round(1)

        def inside?(line, now)
          (now.to_i - Time.parse(line["at"].to_s).to_i) <= @window[:seconds]
        rescue ArgumentError
          false
        end
      end
    end
  end
end
