# frozen_string_literal: true

require "time"
require_relative "plain_sweep"
require_relative "reap_report"

module Hecks
  module Adapters
    class ClaudeCleaning
      # The `Mark` and `SweepPlain` asks of the `Cleaning` port, the two ends of a reap: when it
      # began, and the sessions no run holds with the line that reports the whole.
      #
      # It needs the including adapter's `@command`, `@shell`, `@transcript`, `@runs`, `@registry`,
      # `@tuning` and `listing`.
      module Reaping
        # Says when the reap began, which its report counts from.
        #
        # @return [Hash{Symbol => Hash}] `since:` the time, ISO 8601
        def mark(**)
          { since: { value: clock.call.utc.iso8601 } }
        end

        # Removes the sessions no run holds that are done or stopped, older than `session_keep`
        # hours and in no worktree, then reports the reap.
        #
        # @param held [Hash] the `SessionCleanup` record: `since`
        # @return [Hash{Symbol => Hash}] `report:` the line `removed N sessions and M worktrees;
        #   kept K: <name> (<reason>)`
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def sweep_plain(**held)
          records = @runs.run_records
          swept = sweeper.call(listing, records.map { |run| run[:session] })
          since = held[:since].is_a?(Hash) ? held[:since][:value] : held[:since]
          { report: { value: ReapReport.new(records).line(since, swept) } }
        end

        private

        def sweeper
          PlainSweep.new(keep_hours: keep_hours, now: clock, transcript: @transcript, remove: method(:refusal_of),
                         pinned: @runs.pinned_roles || [])
        end

        def clock = @tuning[:now] || -> { Time.now }

        # The hours a finished session no run holds stays listed: the caller's, else the world's
        # `reaping` line, else a day.
        def keep_hours = @tuning[:session_keep] || reaping_line[:session_keep] || 24

        def reaping_line = @registry&.world("Hecks")&.for_verb("reaping") || {}

        # @return [String, nil] why `claude rm` refused, nil when it removed the session
        def refusal_of(id)
          result = @shell.capture(@command, "rm", id)
          result.ok? ? nil : "#{@command} rm refused: #{result.err.strip}"
        end
      end
    end
  end
end
