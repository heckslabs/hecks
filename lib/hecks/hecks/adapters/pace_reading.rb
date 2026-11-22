# frozen_string_literal: true

require "time"
require "hecks/runtime/event_feed"
require "hecks/adapters/driven/system_clock"
require_relative "pace_reading/rows"
require_relative "pace_reading/count"

module Hecks
  module Adapters
    # The `Pacing` port's adapter for `Pace`: counts the event tap's lines inside a window and
    # answers gross, net and efficiency as text. It reads the log as the `Feed` query does, through
    # `Runtime::EventFeed`, so it boots no domain and writes nothing. The windows, the noise and the
    # finished events are the aggregate's own rows; this reads only facts, the lines and the clock.
    class PaceReading
      # The most tap lines one reading scans: every rotated generation the tap keeps.
      EVERY_LINE = 10**9

      # @param registry [Runtime::Registry, nil] the booted registry; its Hecks world names the tap
      # @param aggregate [Bluebook::Aggregate, nil] `Pace`, whose rows are read
      # @param tap [String, nil] a log in place of the world's, for a spec; a boot never passes it
      def initialize(registry: nil, aggregate: nil, tap: nil, **)
        @registry = registry
        @rows = Rows.new(aggregate)
        @tap = tap
      end

      # @param held [Hash] the query's `window` label (the first `Window` row when absent)
      # @return [Hash{Symbol => String}] `text:` the window, its events and gross, net, efficiency;
      #   all zero where there is no tap or no event in the window
      def read(**held)
        window = @rows.window(plain(held[:window]))
        counted = Count.new(lines, window, @rows, SystemClock.now)
        { text: counted.text }
      end

      private

      def lines
        path = tap_path
        return [] unless path && File.file?(path)

        Runtime::EventFeed.new(path: path).read(since: 0, limit: EVERY_LINE)[:events]
      end

      def tap_path
        return @tap if @tap

        settings = @registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
        Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
