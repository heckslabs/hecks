# frozen_string_literal: true

require "hecks/runtime/event_feed"

module Hecks
  module Adapters
    class OutcomeReadings
      # The event tap a measure is read from: the Hecks world's, moved as a boot moves it
      # (`HECKS_EVENT_TAP`), or the log a spec names in its place. It reads and never writes.
      class Tap
        # The most tap lines one reading takes: every rotated generation the tap keeps.
        EVERY_LINE = 10**9

        # @param registry [Runtime::Registry, nil] the booted registry, whose Hecks world names it
        # @param path [String, nil] a log in place of the world's
        def initialize(registry, path = nil)
          @registry = registry
          @path = path
        end

        # @return [Array<Hash>, nil] every line the tap still keeps, nil when no tap is declared
        def lines
          path = @path || declared
          path && Runtime::EventFeed.new(path: path).read(since: 0, limit: EVERY_LINE)[:events]
        end

        private

        def declared
          settings = @registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
          Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
        end
      end
    end
  end
end
