# frozen_string_literal: true

require_relative "session_role"
require_relative "session_runs"

module Hecks
  module Adapters
    class Metering
      # The ended part of the meter (ADR 0222, phase 3, reaping): each listed background session
      # that is listed done or stopped (finished), or whose process is gone while it is listed
      # otherwise (stale). A session whose process still runs and is not listed ended is not here.
      # It reads only; Signalbox rules on each row before anything is reaped.
      class EndedRows
        # The listing states that mean a session has finished.
        FINISHED = %w[done stopped].freeze

        # @param table [ProcessTable] the machine's processes
        # @param runs [Hash{String => Hash}] each session id's run, as {LiveReads#runs} answers
        # @param activity [#call] takes a listed session, answers its last transcript time or nil
        # @param now [#call] answers the time
        def initialize(table:, runs:, activity:, now:)
          @table = table
          @runs = runs
          @activity = activity
          @now = now
        end

        # @param listing [Array<Hash>] the sessions `claude agents --json --all` lists
        # @return [Array<Hash>] one row for each finished or stale session
        def rows(listing)
          listing.select { |entry| background?(entry) && ended?(entry) }.map { |entry| row(entry) }
        end

        private

        def background?(entry) = entry["kind"].nil? || entry["kind"].to_s == "background"

        def ended?(entry) = finished?(entry) || !live?(entry)

        def finished?(entry) = FINISHED.include?(entry["state"].to_s)

        def live?(entry) = !entry["pid"].nil? && @table.running?(entry["pid"])

        def row(entry)
          listed = %w[id sessionId name state cwd].map { |field| entry[field].to_s }
          { **%i[id session name state cwd].zip(listed).to_h, kind: finished?(entry) ? "finished" : "stale",
            live: live?(entry) ? "yes" : "no", idle_minutes: idle(entry), **of_run(entry) }
        end

        def of_run(entry)
          run = SessionRuns.of(@runs, entry)
          { role: SessionRole.of(entry, run), run: run.to_h[:run].to_s, run_status: run.to_h[:status].to_s }
        end

        def idle(entry)
          last = @activity.call(entry) || Time.at(entry["startedAt"].to_i / MS_PER_SECOND)
          ((@now.call - last) / SECONDS_PER_MINUTE).floor
        end
      end
    end
  end
end
