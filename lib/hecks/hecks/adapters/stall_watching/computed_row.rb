# frozen_string_literal: true

require "time"
require_relative "key"
require_relative "clearing"

module Hecks
  module Adapters
    class StallWatching
      # One `Sighting` row of a computed impediment, built from its `ComputedSignal` row. A computed
      # row is never filed, so its minutes and window are nought: only the impediment view carries it.
      module ComputedRow
        # @param signal [Hash] the `ComputedSignal` row
        # @param run [String] the look that asks
        # @param found [Hash] `subject:` what the row is about, `at:` when the impediment began (a
        #   Time) and `detail:` what the reading found
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @return [Hash] the `Sighting` row, cleared as the signal's row says
        def self.of(signal, run, found, now:)
          subject, at, detail = found.values_at(:subject, :at, :detail)
          stall = Key.of(signal[:kind], subject)
          { id: run, stall: stall, stall_kind: signal[:kind], subject: subject, opened_at: at.utc.iso8601,
            waited: [(now - at.to_i) / 60, 0].max, minutes: 0, forgets: 0, fixer: signal[:fixer],
            title: "#{signal[:kind]}: #{subject}", detail: "#{detail} Fixer: #{signal[:fixer]}. " \
                                                           "Move: #{signal[:move]} Never stop or kill a session.",
            filed: "", count: 1, impediment: stall, cleared_by: Clearing.of(signal) }
        end
      end
    end
  end
end
