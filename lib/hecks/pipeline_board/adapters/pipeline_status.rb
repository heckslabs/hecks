# frozen_string_literal: true

require "time"
require_relative "pipeline_status/why_idle"
require_relative "pipeline_status/throughput"
require_relative "pipeline_status/items"
require_relative "pipeline_stages/cycles"

module Hecks
  module Adapters
    module PipelineBoard
      # The bluebook's one `Status` row: why nothing starts, the throughput windows, each started
      # Work item and each blocked run. It reshapes what the readers answered; a section that was
      # not read leaves its part empty rather than failing the others.
      module PipelineStatus
        module_function

        # @param data [Hash] the board's sections as read, with the standing `load_guard`
        # @param now [Time]
        # @param since [String, nil] a time the throughput also counts from
        # @return [Hash] the `Status` row
        def build(data, now, since = nil)
          found = cycles(data[:cycle_events], now)
          WhyIdle.of(data, idle_minutes(found, now)).merge(
            throughput: Throughput.of(data[:landed_times], now, since),
            items:      StatusItems.items(found, data[:open_work], data[:sessions]),
            blocked:    StatusItems.blocked(data[:sessions])
          )
        end

        # @return [Array<Hash>] the cycles, newest first; none when the events were not read
        def cycles(events, now) = events.is_a?(Array) ? Cycles.build(events, now)[:cycles] : []

        # @return [Integer, nil] minutes since the newest Work item was dispatched
        def idle_minutes(found, now)
          starts = found.filter_map { |cycle| cycle[:stages].find { |entry| entry[:stage] == "dispatch" }&.dig(:start) }
          starts.max && ((now - Time.parse(starts.max)) / 60).floor
        end
      end
    end
  end
end
