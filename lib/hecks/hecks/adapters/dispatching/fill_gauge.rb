# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Dispatching
      # The counts a watch of the fill answers, from values it is handed: how many rollable items
      # wait, the free places under the cap, how many the plan would start, and the whole minutes
      # since the time the `FillStall` record counts from. It reads nothing and decides nothing.
      class FillGauge
        # @param waiting [Integer] the rollable planned work items
        # @param started [Integer] the started work items
        # @param cap [Integer] the cap on started work items
        # @param chosen [Integer] the work items the plan would start now
        def initialize(waiting:, started:, cap:, chosen:)
          @waiting = waiting
          @started = started
          @cap = cap
          @chosen = chosen
        end

        # @param since [String] the time the idle minutes are counted from, as ISO 8601; empty
        #   when the record holds none
        # @param now [Time] the time of the watch
        # @return [Hash{Symbol => Object}] `waiting:`, `room:`, `chosen:`, `idle_minutes:`,
        #   `since:` as handed in, and `now:` as ISO 8601
        def facts(since:, now:)
          { waiting: @waiting, room: [@cap - @started, 0].max, chosen: @chosen,
            idle_minutes: idle_minutes(since, now), since: since, now: now.utc.iso8601 }
        end

        private

        # Nought when no time is recorded yet, or the record's cannot be read.
        def idle_minutes(since, now)
          return 0 if since.empty?

          ((now - Time.iso8601(since)) / 60).floor.clamp(0, nil)
        rescue ArgumentError
          0
        end
      end
    end
  end
end
