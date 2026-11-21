# frozen_string_literal: true

require "time"
require_relative "openings"
require_relative "computed_row"

module Hecks
  module Adapters
    class StallWatching
      # The `held-starts` read: a fill stalled for a reason (the tap's `reason` link holds the row's
      # `pattern`) while the 1-minute load is under the low mark. The hold counts from the later of
      # the stall and the load's last fall (the row's `ends` line), and is an impediment once it has
      # lasted the row's minutes. It reads the tap and one load figure, and boots nothing. A load
      # that cannot be read is itself a row, `impediment view cannot read load`, never a crash.
      class HeldStarts
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param load [#call] answers the 1-minute load, nil (or raises) when unreadable
        # @param low_mark [Float] the load under which the machine could take a start
        def initialize(now, load:, low_mark:)
          @now = now
          @load = load
          @low_mark = low_mark
        end

        # @param signal [Hash] a `ComputedSignal` row of this read
        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks
        # @return [Array<Hash>] one `Sighting` row while the hold has lasted the row's minutes
        def rows(signal, lines, run)
          reading = read_load
          return [unreadable(signal, run)] unless reading
          return [] unless reading < @low_mark

          openings = Openings.new(signal.merge(closed_by: "any"), lines)
          openings.unclosed.filter_map do |subject, opened|
            held = held_since(signal, lines, opened)
            next unless held && openings.links(subject)["reason"].to_s.include?(signal[:pattern].to_s)

            row(signal, run, subject, held, reading)
          end
        end

        private

        def read_load
          @load.call
        rescue StandardError
          nil
        end

        def unreadable(signal, run)
          found = { subject: "load", at: Time.at(@now), detail: "impediment view cannot read load: the 1-minute load " \
                                                                "gave no figure, so held starts cannot be judged." }
          ComputedRow.of(signal, run, found, now: @now)
        end

        def held_since(signal, lines, opened)
          at = [Time.iso8601(opened), fall(signal, lines)].compact.max
          at if (@now - at.to_i) / 60 >= signal[:minutes].to_i
        end

        def fall(signal, lines)
          ended = signal[:ends].to_s.split(",")
          line = lines.reverse_each.find { |one| one["aggregate"] == signal[:ends_aggregate] && ended.include?(one["event"]) }
          Time.iso8601(line["at"]) if line
        end

        def row(signal, run, subject, since, reading)
          detail = "#{signal[:aggregate]} #{subject} has held starts (#{signal[:pattern]}) since #{since.utc.iso8601} " \
                   "while the 1-minute load is #{reading.round(1)}, under the low mark #{@low_mark}."
          ComputedRow.of(signal, run, { subject: subject, at: since, detail: detail }, now: @now)
        end
      end
    end
  end
end
