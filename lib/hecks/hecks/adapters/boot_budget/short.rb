# frozen_string_literal: true

module Hecks
  module Adapters
    class BootBudget
      # The short windows of the launcher's usage record: the share of the machine's CPU the boots
      # of the last few minutes took, and the callers that booted over a rate in the last few
      # minutes. Only runs that carry a start time are placed in a window, so a run nobody dated
      # is never held against anyone. A read the byte limit cut short is a floor, so a flood of
      # launcher runs can only raise a reading, never hide in it.
      module Short
        # Milliseconds in a minute.
        MINUTE_MS = 60_000.0

        # The boot share of a window. `percent` is the boot time over the window's CPU time;
        # `capped` is true when the read was cut short, so `percent` is a floor.
        Share = Struct.new(:percent, :capped, keyword_init: true)

        # @param minutes [Numeric] the window's length
        # @param cpus [Numeric] the machine's CPU count
        # @return [Share] boot time as a percent of the CPU time the window holds
        def share(minutes:, cpus:)
          rows, capped = within(minutes)
          Share.new(percent: (boot_ms(rows) * 100 / (minutes * MINUTE_MS * cpus)).round(1), capped: capped)
        end

        # @param boots [Integer] the most boots a caller may make in the window
        # @param minutes [Numeric] the window's length
        # @return [Hash{String => Integer}] each named caller over the rate, most boots first
        def storms(boots:, minutes:)
          counts = within(minutes).first.filter_map { |row| row["caller"] }.tally
          counts.select { |_, count| count > boots }.sort_by { |name, count| [-count, name] }.to_h
        end

        # @return [Time, nil] when the oldest boots leave the window far enough that the share
        #   falls to the mark, nil when it is already there or the stamped runs cannot bring it
        def share_frees_at(percent:, minutes:, cpus:)
          rows = within(minutes).first.select { |row| row["boot_ms"].is_a?(Numeric) }
          owed = boot_ms(rows) - (percent / 100.0 * minutes * MINUTE_MS * cpus)
          leaves_when(rows.sort_by { |row| UsageTail.stamp(row) }, owed, minutes) unless owed <= 0
        end

        private

        def within(minutes)
          since = @now.call - (minutes * 60)
          entries = @entries.call(since)
          rows = Array(entries).select { |row| (UsageTail.stamp(row) || (since - 1)) >= since }
          [rows, capped_by?(entries)]
        end

        def boot_ms(rows) = rows.sum { |row| row["boot_ms"].is_a?(Numeric) ? row["boot_ms"] : 0 }

        def leaves_when(oldest_first, owed, minutes)
          oldest_first.each do |row|
            owed -= row["boot_ms"]
            return UsageTail.stamp(row) + (minutes * 60) if owed <= 0
          end
          nil
        end
      end
    end
  end
end
