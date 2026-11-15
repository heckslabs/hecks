# frozen_string_literal: true

require "date"
require "time"
require_relative "../zone"

module Hecks
  module Adapters
    module PipelineBoard
      # The Work items finished on each of the last days, for the board's throughput chart. A day
      # is the calendar day in Arizona ({Zone}), and today is the last and still open.
      module ThroughputDays
        # How many days the chart shows, today included.
        DAYS = 14

        module_function

        # @param times [Array<String>, Hash] when each Work item finished, or `{unknown: reason}`
        # @param now [Time]
        # @return [Hash] `days` (oldest first: `day`, `label` and `finished`) and `average` (a
        #   day, over the days before today), or the `{unknown: reason}` as it was read
        def build(times, now)
          return times unless times.is_a?(Array)

          counts = times.filter_map { |at| day_of(at, now) }.tally
          days = window(now).map { |date| { day: date.iso8601, label: date.strftime("%a %-d"), finished: counts.fetch(date, 0) } }
          { days: days, average: average(days[0...-1]) }
        end

        # The calendar days shown, oldest first, ending today.
        def window(now)
          today = Zone.day(now)
          ((today - (DAYS - 1))..today).to_a
        end

        # The day a time falls on in Arizona, nil for a time that cannot be read.
        def day_of(at, _now)
          Zone.day(at)
        rescue ArgumentError
          nil
        end

        def average(days) = days.empty? ? 0 : (days.sum { |day| day[:finished] }.to_f / days.size).round
      end
    end
  end
end
