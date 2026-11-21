# frozen_string_literal: true

require "time"
require_relative "computed_row"

module Hecks
  module Adapters
    class StallWatching
      # The `landing-rate` read: the lines that open the row in its window (an hour) against the same
      # lines in three windows. It is an impediment while the window holds fewer than `limit` percent
      # of one window's share of the three. It reads the tap and says nothing of why.
      class LandingRate
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        def initialize(now)
          @now = now
        end

        # @param signal [Hash] a `ComputedSignal` row of this read
        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks
        # @return [Array<Hash>] one `Sighting` row while the window is under the row's share
        def rows(signal, lines, run)
          window = signal[:minutes].to_i
          recent = counted(signal, lines, window)
          share = counted(signal, lines, window * 3) / 3.0
          return [] unless recent < share * signal[:limit].to_i / 100.0

          [row(signal, run, recent, share)]
        end

        private

        def counted(signal, lines, minutes)
          since = @now - (minutes * 60)
          lines.count { |line| match?(signal, line) && Time.iso8601(line["at"]).to_i >= since }
        end

        def match?(signal, line) = line["aggregate"] == signal[:aggregate] && line["event"] == signal[:opens]

        def row(signal, run, recent, share)
          detail = "#{recent} #{signal[:opens]} in the last #{signal[:minutes]} minutes against " \
                   "#{share.round(1)} an hour over the last #{signal[:minutes].to_i * 3}."
          ComputedRow.of(signal, run, { subject: "landings", at: Time.at(@now), detail: detail }, now: @now)
        end
      end
    end
  end
end
