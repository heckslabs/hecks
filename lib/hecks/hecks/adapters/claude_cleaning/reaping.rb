# frozen_string_literal: true

require "time"
require "hecks/agents/adapters/hand_run_hold"
require_relative "plain_sweep"
require_relative "reap_report"
require_relative "../claude_jobs"
require_relative "../session_reaping"

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

        # Removes the sessions no run holds that are done or stopped, in no worktree and older than
        # their {KeepWindow}: `remove_done_after_minutes` for a helper the pipeline launched,
        # `session_keep` hours for the owner's; then reports the reap. Once the Tickets world's
        # `reaping.signalbox` is on, Signalbox reaps instead ({SignalboxReap}).
        #
        # @param held [Hash] the `SessionCleanup` record: `since`
        # @return [Hash{Symbol => Hash}] `report:` the line `removed N sessions and M worktrees;
        #   kept K: <name> (<reason>)`
        # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
        def sweep_plain(**held)
          return signalbox_report if ReapingSwitch.on?(@registry)

          records = @runs.run_records
          swept = sweeper.call(listing, records.map { |run| run[:session] })
          since = held[:since].is_a?(Hash) ? held[:since][:value] : held[:since]
          { report: { value: ReapReport.new(records).line(since, swept) } }
        end

        private

        def sweeper
          PlainSweep.new(window: window, now: clock, transcript: @transcript, remove: method(:refusal_of),
                         hold: hold)
        end

        def hold = @tuning[:hold] || HandRunHold.new(registry: @registry)

        def window
          KeepWindow.new(owner_hours: keep_hours, helper_minutes: helper_minutes, jobs: ClaudeJobs.from(@tuning),
                         pinned: @runs.pinned_roles || [])
        end

        # The minutes a finished helper session no run holds stays listed: the caller's, else the
        # world's `reaping` line ({SessionReaping#remove_done_after}).
        def helper_minutes = @tuning[:remove_done_after] || SessionReaping.new(registry: @registry).remove_done_after

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
