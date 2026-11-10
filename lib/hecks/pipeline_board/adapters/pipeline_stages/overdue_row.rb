# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "stopped_row"

module Hecks
  module Adapters
    module PipelineBoard
      # The strip's first row while a stopped run has waited on a person too long: for each open
      # stopped-run finding the `Stopped run age` rows judge overdue, its run, stage, the hours it
      # has waited and the first line of its reason. Nothing while none is overdue.
      module OverdueRow
        NAME = "Overdue for you"

        module_function

        # @param runs [Array<Hash>, Hash, nil] the `stopped_runs` section, or `{unknown:}`
        # @param times [Hash, nil] the finding's key to the time it was reported, or `{unknown:}`
        # @param now [Time] the time the board is read at
        # @return [Array<Hash>] each open stop with its `hours` (nil when its time is unknown) and
        #   whether it is `overdue`
        def aged(runs, times, now)
          return [] unless runs.is_a?(Array)

          runs.map do |run|
            hours = hours_since(times, run[:finding], now)
            run.merge(hours: hours, overdue: Rules.verdict("Stopped run age", { hours: hours }) == "overdue")
          end
        end

        # @param stops [Array<Hash>] the {aged} stops
        # @return [Array<Hash>] one row with `name`, `state`, `count` and `detail`, or none
        def build(stops)
          late = stops.select { |stop| stop[:overdue] }
          return [] if late.empty?

          [{ name: NAME, state: Rules.verdict(NAME, {}), count: late.size.to_s,
             detail: late.map { |stop| line(stop) }.join("; ") }]
        end

        # @param stop [Hash] one overdue stop
        # @return [String] its run, stage, hours waited and the first line of its reason
        def line(stop)
          "#{stop[:finding].to_s[0, 10]} at #{stop[:stage]} for #{stop[:hours].round(1)} h: " \
            "#{StoppedRow.first_line(stop[:body].to_s)}"
        end

        # The hours since the finding was reported, nil when its time cannot be read.
        def hours_since(times, key, now)
          at = times.is_a?(Hash) && !times.key?(:unknown) ? times[key.to_s] : nil
          at ? (now - Time.parse(at.to_s)) / 3600.0 : nil
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
