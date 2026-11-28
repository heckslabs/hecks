# frozen_string_literal: true

require "time"
require "hecks/runtime/event_feed"

module Hecks
  module Adapters
    class CrewUsage
      # The work items the event tap shows finished inside one window, read and never written, as
      # the Velocity port reads a day.
      class Finished
        # The most tap lines one read takes: every rotated generation the tap keeps.
        EVERY_LINE = 10**9

        # @param tap [String, nil] the tap's path; the live tap when nil
        def initialize(tap)
          @tap = tap
        end

        # @param window [Range<Time>] the moments a finish is counted in
        # @return [Integer] the distinct work items finished in the window
        def count(window)
          items = finishes.select { |line| window.cover?(Time.iso8601(line["at"].to_s)) }
          items.map { |line| line["id"].to_s }.uniq.size
        end

        private

        def finishes
          lines = Runtime::EventFeed.new(path: @tap).read(since: 0, limit: EVERY_LINE)[:events]
          lines.select { |line| finished?(line) }
        end

        def finished?(line) = line["aggregate"] == "Tickets::Work" && line["event"] == "WorkFinished" && line["at"]
      end
    end
  end
end
