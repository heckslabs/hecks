# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "../zone"

module Hecks
  module Adapters
    module PipelineBoard
      # Landings in the status's windows: the last hour, today since the `status_day_start_hour`
      # (Arizona), and since a time the caller names. Each is a count and its rate per hour.
      module Throughput
        module_function

        # @param landed [Hash{String => String}, Hash] sha to landing time, or `{unknown: reason}`
        # @param now [Time]
        # @param since [String, nil] a time to count from
        # @return [Array<Hash>] one `Throughput` row per window
        def of(landed, now, since)
          times = landed.is_a?(Hash) && !landed.key?(:unknown) ? landed.values.filter_map { |at| parse(at) } : nil
          windows(now, since).map { |name, from| row(name, from, times, now) }
        end

        # @return [Array<Array>] the window names and where each opens
        def windows(now, since)
          hour = now - (Rules.setting("status_hour_minutes") * 60)
          list = [["last hour", hour], ["today since noon", day_start(now)]]
          mark = since && parse(since)
          mark ? list + [["since #{since}", mark]] : list
        end

        def day_start(now)
          local = Zone.at(now)
          Time.new(local.year, local.month, local.day, Rules.setting("status_day_start_hour"), 0, 0, Zone::OFFSET)
        end

        def row(name, from, times, now)
          count = times&.count { |at| at.between?(from, now) }
          { window: name, since: from.utc.iso8601, landings: count.to_i, per_hour: rate(count, from, now) }
        end

        # @return [String] landings per hour over the window, empty when unread or empty
        def rate(count, from, now)
          hours = (now - from) / 3600.0
          count.nil? || hours <= 0 ? "" : format("%.1f", count / hours)
        end

        # @return [Time, nil] the time the text names, nil when it cannot be read
        def parse(at)
          Time.parse(at.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
