# frozen_string_literal: true

require "date"

module Hecks
  module Adapters
    class LandingPaceReading
      # The text of a measure: the landings of each UTC day, then the totals and the wait from
      # ready to landed. A day with no landing between the first and the last counts as zero.
      class Report
        # @param pairing [Pairing] the landings, each with its wait, and the refusals
        # @param days [Integer] the length of the window measured
        # @param source [String] the file the events were read from
        def initialize(pairing, days:, source:)
          @pairing = pairing
          @days = days
          @source = source
        end

        # @return [String] one line per fact
        def text
          return "no landing is recorded in the last #{@days} days of #{@source}" if @pairing.landed.empty?

          ["landings by UTC day, the last #{@days} days of #{@source}", *day_lines, landed_line,
           "refused: #{@pairing.refused}", wait_line, *unpaired_line].join("\n")
        end

        private

        def per_day
          @per_day ||= begin
            counts = @pairing.landed.map { |landing| landing.at.utc.to_date }.tally
            (counts.keys.min..counts.keys.max).to_h { |day| [day, counts.fetch(day, 0)] }
          end
        end

        def day_lines = per_day.map { |day, count| "  #{day}  #{count}" }

        def landed_line
          counts = per_day.values
          day, most = per_day.max_by { |_day, count| count }
          "landed: #{counts.sum} in #{counts.size} days: mean #{(counts.sum.to_f / counts.size).round(1)} a day, " \
            "median #{middle(counts)}, busiest #{most} on #{day}"
        end

        def wait_line
          waits = @pairing.landed.filter_map(&:wait).sort
          return "ready to landed: no landing has a request in the window" if waits.empty?

          "ready to landed, #{waits.size} landings: median #{span(rank(waits, 0.5))}, " \
            "p90 #{span(rank(waits, 0.9))}, longest #{span(waits.last)}"
        end

        def unpaired_line
          missing = @pairing.landed.count { |landing| landing.wait.nil? }
          missing.zero? ? [] : ["no request in the window for #{missing} landings: left out of the wait"]
        end

        def middle(counts)
          sorted = counts.sort
          ((sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0).round(1)
        end

        # The nearest-rank percentile of sorted values.
        def rank(sorted, share) = sorted[[(share * sorted.size).ceil - 1, 0].max]

        def span(seconds)
          minutes, rest = seconds.round.divmod(60)
          minutes.zero? ? "#{rest}s" : "#{minutes}m #{rest}s"
        end
      end
    end
  end
end
