# frozen_string_literal: true

require_relative "held_starts"
require_relative "finished_runs"
require_relative "landing_rate"
require_relative "leftovers"
require_relative "leftover_reads"

module Hecks
  module Adapters
    class StallWatching
      # The computed impediments read from the tap and cheap machine readings, each by the `read` its
      # `ComputedSignal` row names. A row never files: only the impediment view carries it.
      class Computed
        # The reads this class answers; `shared-files` is {SharedFiles}'s.
        READS = %w[held-starts leftovers run-finished landing-rate].freeze

        # @param signals [Array<Hash>] the `ComputedSignal` rows
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        # @param reads [Hash] `load:` the 1-minute load, `low_mark:` the mark it is judged against,
        #   `counts:` a leftover's count by name ({LeftoverReads})
        def initialize(signals, now, **reads)
          @signals = signals.select { |signal| READS.include?(signal[:read]) }
          @now = now
          @reads = reads
        end

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks
        # @return [Array<Hash>] the `Sighting` rows of every signal that holds
        def rows(lines, run)
          @signals.flat_map { |signal| read(signal[:read]).rows(signal, lines, run) }
        end

        private

        def read(name)
          case name
          when "held-starts" then HeldStarts.new(@now, load: @reads[:load], low_mark: @reads[:low_mark])
          when "leftovers" then Leftovers.new(@now, counts: @reads[:counts])
          when "run-finished" then FinishedRuns.new(@now)
          else LandingRate.new(@now)
          end
        end
      end
    end
  end
end
