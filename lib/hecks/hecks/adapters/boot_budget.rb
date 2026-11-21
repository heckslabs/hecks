# frozen_string_literal: true

require "time"
require_relative "boot_budget/usage_tail"
require_relative "boot_budget/short"

module Hecks
  module Adapters
    # What the launcher's boots cost, read from the usage record: the hours over the last day and
    # who booted in the last hour, both readings for the board and never a brake, and, through
    # {Short}, the boot share and the boot storms of the last few minutes, which are the signals a
    # fill holds on.
    #
    # The day is the 24 hours before now, from the time each run began (`at`), not the calendar
    # day. Each recorded run carries `boot_ms`, the time from the launcher's first line to its
    # command. Only those runs are priced: a run with a start time and no boot time is counted
    # apart as unmeasured and adds no hours.
    class BootBudget
      include Short

      # Seconds in an hour, and milliseconds in one.
      HOUR = 3600
      HOUR_MS = 3_600_000.0

      # The length of the day the reading covers, in seconds.
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
        rows = Array(entries).select { |row| UsageTail.recent?(row, cutoff) }
        reading(rows, now, capped_by?(entries))
      end

      private

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
