# frozen_string_literal: true

require "time"
require_relative "boot_budget/usage_tail"

module Hecks
  module Adapters
    # What the launcher's boots cost over the last day, read from the usage record: the hours spent
    # booting, and who booted in the last hour. It reads and decides nothing; the board shows it and
    # a fill compares it with the budget the Tickets world declares.
    #
    # The day is the 24 hours before now, from the time each run began (`at`), not the calendar
    # day. Each recorded run carries `boot_ms`, the time from the launcher's first line to its
    # command. Only those runs are priced: a run with a start time and no boot time is counted
    # apart as unmeasured and adds no hours, so a budget is never spent by runs nobody measured.
    class BootBudget
      # Seconds in an hour, and milliseconds in one.
      HOUR = 3600
      HOUR_MS = 3_600_000.0

      # The length of the window the budget is a ceiling over, in seconds.
      WINDOW = 24 * HOUR

      # What one reading says. `hours` is the measured boot time in the window; `boots` the runs
      # in it; `unmeasured` those with no `boot_ms`; `last_hour` the runs in the last hour per
      # caller.
      Reading = Struct.new(:hours, :boots, :unmeasured, :last_hour, keyword_init: true)

      # @param entries [#call, nil] answers the usage entries since a time; the tail of the
      #   launcher's own record, one bounded read, when nil
      # @param now [#call, nil] answers the time; the clock's when nil
      def initialize(entries: nil, now: nil)
        @entries = entries || UsageTail.method(:since)
        @now = now || -> { Time.now.utc }
      end

      # @return [Reading] what the boots of the last 24 hours cost
      def today
        now = @now.call
        cutoff = now - WINDOW
        reading(Array(@entries.call(cutoff)).select { |row| UsageTail.recent?(row, cutoff) }, now)
      end

      # @param budget [Numeric] the hours of boots a day allows
      # @return [String, nil] why no session starts: the measured boots of the last day have spent
      #   the budget, else nil
      def stop_reason(budget)
        spent = today.hours
        "skipped: boot budget spent: #{spent.round(2)} of #{budget.to_f.round(2)} hours" if spent >= budget.to_f
      end

      private

      def reading(rows, now)
        measured = rows.select { |row| row["boot_ms"].is_a?(Numeric) }
        Reading.new(hours: hours(measured), boots: rows.size, unmeasured: rows.size - measured.size,
                    last_hour: last_hour(rows, now))
      end

      def hours(measured) = (measured.sum { |row| row["boot_ms"] } / HOUR_MS).round(3)

      # The runs in the last hour per caller, most first; a run naming nobody is "unnamed".
      def last_hour(rows, now)
        since = now - HOUR
        recent = rows.select { |row| (UsageTail.stamp(row) || (since - 1)) >= since }
        callers_by_runs(recent.map { |row| row["caller"] || "unnamed" })
      end

      # @return [Hash{String => Integer}] each caller's runs, the most runs first
      def callers_by_runs(names) = names.tally.sort_by { |name, count| [-count, name] }.to_h
    end
  end
end
