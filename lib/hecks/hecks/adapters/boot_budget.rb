# frozen_string_literal: true

require "time"
require_relative "boot_budget/usage_tail"

module Hecks
  module Adapters
    # What the launcher's boots cost, read from the usage record: the hours spent booting over the
    # last day (a reading for the board), the hours over a short window (the last hour by default),
    # and who booted in the last hour. A fill compares the short window with the budget the Tickets
    # world declares, taken as a rate per hour, so a boot storm trips it and an idle hour frees it.
    #
    # The day is the 24 hours before now, from the time each run began (`at`), not the calendar
    # day. Each recorded run carries `boot_ms`, the time from the launcher's first line to its
    # command. Only those runs are priced: a run with a start time and no boot time is counted
    # apart as unmeasured and adds no hours, so a budget is never spent by runs nobody measured.
    class BootBudget
      # Seconds in an hour, and milliseconds in one.
      HOUR = 3600
      HOUR_MS = 3_600_000.0

      # The length of the day the budget is declared over, in seconds.
      WINDOW = 24 * HOUR

      # The short window the stop rule compares, in seconds, when none is given.
      SHORT_WINDOW = HOUR

      # What one reading says. `hours` is the measured boot time in the window; `boots` the runs
      # in it; `unmeasured` those with no `boot_ms`; `last_hour` the runs in the last hour per
      # caller; `approximate` the runs that carry no start time, placed in the window by their day
      # alone; `capped` whether the byte limit cut the read short of the window's start, so `hours`
      # is a floor; `recent_hours` the measured boot time in the short window, from runs that carry
      # a start time; `recent_capped` whether the limit cut the read short of the short window.
      Reading = Struct.new(:hours, :boots, :unmeasured, :last_hour, :approximate, :capped,
                           :recent_hours, :recent_capped, keyword_init: true)

      # @param entries [#call, nil] answers the usage entries since a time; the tail of the
      #   launcher's own record, one bounded read, when nil
      # @param now [#call, nil] answers the time; the clock's when nil
      # @param window [Numeric] the short window the stop rule compares, in seconds
      def initialize(entries: nil, now: nil, window: SHORT_WINDOW)
        @entries = entries || UsageTail.method(:since)
        @now = now || -> { Time.now.utc }
        @window = window
      end

      # @return [Reading] what the boots of the last 24 hours cost
      def today
        now = @now.call
        cutoff = now - WINDOW
        entries = @entries.call(cutoff)
        rows = Array(entries).select { |row| UsageTail.recent?(row, cutoff) }
        reading(rows, now, capped_by?(entries), recent_capped?(entries, rows, now - @window))
      end

      # The budget is spent when the boots of the short window reach its share of the day: the
      # budget as a rate per hour, over the window's length. The day's `hours` is a reading, not the
      # stop rule, so a quiet last hour starts work after a busy day and a storm in the last hour
      # stops it. When the byte limit cut the read short of the short window, its hours are a floor,
      # so half the allowance already spent is judged probably spent: a runaway of launcher runs is
      # what fills the limit, and it must not hide itself by overflowing the read.
      #
      # @param budget [Numeric] the hours of boots a day allows
      # @return [String, nil] why no session starts: the measured boots of the short window have
      #   spent their share of the budget, else nil
      def stop_reason(budget)
        reading = today
        limit = allowance(budget)
        if reading.recent_hours >= limit
          spent_line("spent", reading.recent_hours, limit)
        elsif reading.recent_capped && reading.recent_hours >= limit / 2
          spent_line("probably spent (the read was cut short)", reading.recent_hours, limit)
        end
      end

      # When the budget can next free by the window alone: the time the oldest measured runs leave
      # the short window far enough that its hours fall under the allowance. The clock's beat does
      # not read the usage record again before then unless the record changes.
      #
      # @param budget [Numeric] the hours of boots a day allows
      # @return [Time, nil] that time, nil when the stamped runs alone cannot bring the hours under
      def frees_at(budget)
        measured = measured_rows(@now.call - @window)
        owed = hours(measured) - allowance(budget)
        leaves_when(measured.sort_by { |row| UsageTail.stamp(row) }, owed) unless owed.negative?
      end

      private

      # The runs since the cutoff that carry a boot time and a start time.
      def measured_rows(cutoff)
        Array(@entries.call(cutoff)).select do |row|
          row["boot_ms"].is_a?(Numeric) && (UsageTail.stamp(row) || (cutoff - 1)) >= cutoff
        end
      end

      # The time the run that brings the owed hours to nothing leaves the short window.
      def leaves_when(oldest_first, owed)
        oldest_first.each do |row|
          owed -= row["boot_ms"] / HOUR_MS
          return UsageTail.stamp(row) + @window if owed.negative?
        end
        nil
      end

      # The budget as a rate per hour: the day's hours over the hours in the day. The world will
      # declare the rate itself; this is the one place that derives it.
      def rate_per_hour(budget) = budget.to_f * HOUR / WINDOW

      # The hours the short window may spend: the hourly rate over the window's length.
      def allowance(budget) = rate_per_hour(budget) * @window / HOUR

      def spent_line(word, hours, limit)
        "skipped: boot budget #{word}: #{hours.round(2)} of #{limit.round(2)} hours in #{span}"
      end

      def span = @window == HOUR ? "the last hour" : "the last #{(@window / 60.0).round(1)} minutes"

      # Whether the byte limit cut the read short of the short window: the oldest stamped run read
      # is newer than the window's start, or none could be read at all.
      def recent_capped?(entries, rows, since)
        return false unless capped_by?(entries)

        oldest = rows.filter_map { |row| UsageTail.stamp(row) }.min
        oldest.nil? || oldest > since
      end

      def capped_by?(entries) = entries.respond_to?(:capped) && entries.capped == true

      def reading(rows, now, capped, recent_capped)
        measured = rows.select { |row| row["boot_ms"].is_a?(Numeric) }
        Reading.new(hours: hours(measured), boots: rows.size, unmeasured: rows.size - measured.size,
                    last_hour: last_hour(rows, now), approximate: rows.count { |row| UsageTail.approximate?(row) },
                    capped: capped, recent_hours: hours(recent(measured, now - @window)), recent_capped: recent_capped)
      end

      # The measured runs that began at or after the short window's start.
      def recent(measured, since) = measured.select { |row| (UsageTail.stamp(row) || (since - 1)) >= since }

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
