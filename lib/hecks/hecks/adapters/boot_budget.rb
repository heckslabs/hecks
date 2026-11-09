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
      # caller; `approximate` the runs that carry no start time, placed in the window by their day
      # alone; `capped` whether the byte limit cut the read short of the window's start, so `hours`
      # is a floor.
      Reading = Struct.new(:hours, :boots, :unmeasured, :last_hour, :approximate, :capped, keyword_init: true)

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
        entries = @entries.call(cutoff)
        reading(Array(entries).select { |row| UsageTail.recent?(row, cutoff) }, now, capped_by?(entries))
      end

      # The budget is spent when the measured hours reach it. When the byte limit cut the read short
      # of the window's start, the hours are a floor, so a budget the floor has already half spent
      # is judged probably spent: a runaway of launcher runs is exactly what fills the limit, and it
      # must not hide itself by overflowing the read. A truncated read below half the budget stops
      # nothing; the board shows the window as truncated.
      #
      # @param budget [Numeric] the hours of boots a day allows
      # @return [String, nil] why no session starts: the measured boots of the last day have spent
      #   the budget, else nil
      def stop_reason(budget)
        reading = today
        limit = budget.to_f
        if reading.hours >= limit
          spent_line("spent", reading.hours, limit)
        elsif capped_half?(reading, limit)
          spent_line("probably spent (the read was cut short)", reading.hours, limit)
        end
      end

      # When the budget can next free by the window alone: the time the oldest measured runs leave
      # it far enough that the hours fall under the budget. The clock's beat does not read the usage
      # record again before then unless the record changes.
      #
      # @param budget [Numeric] the hours of boots a day allows
      # @return [Time, nil] that time, nil when the stamped runs alone cannot bring the hours under
      def frees_at(budget)
        measured = measured_rows(@now.call - WINDOW)
        owed = hours(measured) - budget.to_f
        leaves_when(oldest_first(measured), owed) unless owed.negative?
      end

      private

      # The runs in the window that carry a boot time.
      def measured_rows(cutoff)
        Array(@entries.call(cutoff)).select { |row| UsageTail.recent?(row, cutoff) && row["boot_ms"].is_a?(Numeric) }
      end

      def oldest_first(rows) = rows.select { |row| UsageTail.stamp(row) }.sort_by { |row| UsageTail.stamp(row) }

      # The time the run that brings the owed hours to nothing leaves the window.
      def leaves_when(oldest_first, owed)
        oldest_first.each do |row|
          owed -= row["boot_ms"] / HOUR_MS
          return UsageTail.stamp(row) + WINDOW if owed.negative?
        end
        nil
      end

      def spent_line(word, hours, limit) = "skipped: boot budget #{word}: #{hours.round(2)} of #{limit.round(2)} hours"

      def capped_half?(reading, limit) = reading.capped && reading.hours >= limit / 2

      def capped_by?(entries) = entries.respond_to?(:capped) && entries.capped == true

      def reading(rows, now, capped)
        measured = rows.select { |row| row["boot_ms"].is_a?(Numeric) }
        Reading.new(hours: hours(measured), boots: rows.size, unmeasured: rows.size - measured.size,
                    last_hour: last_hour(rows, now), approximate: rows.count { |row| UsageTail.approximate?(row) },
                    capped: capped)
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
