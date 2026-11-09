# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    # What the launcher's boots cost today, read from the usage record: the hours spent booting,
    # and who booted in the last hour. It reads and decides nothing; the board shows it and a fill
    # compares it with the budget the Tickets world declares.
    #
    # Each recorded run carries `boot_ms`, the time from the launcher's first line to its command.
    # A run recorded before that field existed has none: it counts at the median of the runs that
    # do, and is counted apart as unmeasured, or left out when no run today has one.
    class BootBudget
      # Seconds in an hour, and milliseconds in one.
      HOUR = 3600
      HOUR_MS = 3_600_000.0

      # What one reading says. `hours` is the boot time today; `boots` the runs today;
      # `unmeasured` those with no `boot_ms`; `last_hour` the runs in the last hour per caller.
      Reading = Struct.new(:hours, :boots, :unmeasured, :last_hour, keyword_init: true)

      # @param entries [#call, nil] answers the usage entries of one day, given its date as
      #   year-month-day text; the launcher's own record when nil
      # @param now [#call, nil] answers the time; the clock's when nil
      def initialize(entries: nil, now: nil)
        @entries = entries || method(:recorded)
        @now = now || -> { Time.now.utc }
      end

      # @return [Reading] what the boots of today cost
      def today
        now = @now.call
        rows = Array(@entries.call(now.strftime("%Y-%m-%d")))
        measured = rows.filter_map { |row| row["boot_ms"] if row["boot_ms"].is_a?(Numeric) }
        unmeasured = rows.size - measured.size
        Reading.new(hours: hours(measured, unmeasured), boots: rows.size, unmeasured: unmeasured,
                    last_hour: last_hour(rows, now))
      end

      # @param budget [Numeric] the hours of boots a day allows
      # @return [String, nil] why no session starts: the day's boots have spent the budget, else nil
      def stop_reason(budget)
        spent = today.hours
        "skipped: boot budget spent: #{spent.round(2)} of #{budget.to_f.round(2)} hours" if spent >= budget.to_f
      end

      private

      # The hours of boot time: the measured runs, plus the median for each run with none.
      def hours(measured, unmeasured)
        return 0.0 if measured.empty?

        sorted = measured.sort
        total = measured.sum + (sorted[sorted.size / 2] * unmeasured)
        (total / HOUR_MS).round(3)
      end

      # The runs in the last hour per caller, most first; a run naming nobody is "unnamed".
      def last_hour(rows, now)
        since = now - HOUR
        recent = rows.select { |row| (stamp(row) || (since - 1)) >= since }
        callers_by_runs(recent.map { |row| row["caller"] || "unnamed" })
      end

      # @return [Hash{String => Integer}] each caller's runs, the most runs first
      def callers_by_runs(names) = names.tally.sort_by { |name, count| [-count, name] }.to_h

      def stamp(row)
        Time.parse(row["at"].to_s) if row["at"]
      rescue ArgumentError
        nil
      end

      # The launcher's own record: the lines of one day, found before they are parsed.
      def recorded(date)
        marker = %("date":"#{date}")
        File.foreach(Driving::UsageLog.path).filter_map do |line|
          JSON.parse(line) if line.include?(marker)
        rescue JSON::ParserError
          nil
        end
      rescue SystemCallError
        []
      end
    end
  end
end
