# frozen_string_literal: true

require_relative "computed_row"

module Hecks
  module Adapters
    class StallWatching
      # The `leftovers` read: what a clean-up has not removed, one row per `ComputedSignal` row whose
      # count (named by its `pattern`) is over its `limit`. It has no age, so it began now.
      class Leftovers
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param counts [#call] answers a leftover's count by its name ({LeftoverReads})
        def initialize(now, counts:)
          @now = now
          @counts = counts
        end

        # @param signal [Hash] a `ComputedSignal` row of this read
        # @param _lines [Array<Hash>] tap lines, unused
        # @param run [String] the look that asks
        # @return [Array<Hash>] one `Sighting` row when the count is over the row's limit
        def rows(signal, _lines, run)
          count = @counts.call(signal[:pattern])
          return [] unless count > signal[:limit].to_i

          detail = "#{count} #{signal[:pattern]} stand, over the limit of #{signal[:limit]}."
          [ComputedRow.of(signal, run, { subject: signal[:pattern], at: Time.at(@now), detail: detail }, now: @now)]
        end
      end
    end
  end
end
