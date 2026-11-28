# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class PaceReading
      # The count of chosen events by name inside one window, noise included.
      class Named
        # @param lines [Array<Hash>] the tap's lines
        # @param window [Hash] the `Window` row (`label`, `seconds`)
        # @param now [Integer] the clock's now, in epoch seconds
        def initialize(lines, window, now)
          @window = window
          @inside = lines.select { |line| line["kind"] == "event" && inside?(line, now) }
        end

        # @param names [Array<String>] the events to count
        # @return [String] the window and one `Name: n` line for each name
        def text(names)
          ["window: #{@window[:label]}", *names.map { |name| "#{name}: #{@inside.count { |l| l["event"] == name }}" }].join("\n")
        end

        private

        def inside?(line, now)
          (now.to_i - Time.parse(line["at"].to_s).to_i) <= @window[:seconds]
        rescue ArgumentError
          false
        end
      end
    end
  end
end
