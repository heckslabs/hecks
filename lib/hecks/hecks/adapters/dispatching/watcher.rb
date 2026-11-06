# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class Dispatching
      # Acts on the bloated started rows: stops the session of each, when the `Agents` adapter can,
      # and yields the row to the plan with `bloat: <rule>` as the reason. Without `confirm` it says
      # what it would do and does nothing.
      #
      # A session that cannot be stopped (none recorded, or the stop refused) is reported as
      # "cannot stop: tell the owner" and the row is still yielded, so the stuck step shows in the plan.
      class Watcher
        # @param breaches [Array<IterationWatch::Breach>] what the rules found
        # @param runs [Hash{String => Hash}] each agent run's `status:` and `session:`, by key
        # @param launcher [Launcher] yields rows and checks sessions
        # @param stopper [#call] `(session)` stops one session, raising ConsoleCapture::Failure when it cannot
        def initialize(breaches, runs, launcher, stopper:)
          @breaches = breaches
          @runs = runs
          @launcher = launcher
          @stopper = stopper
        end

        # @param confirm [Boolean] act, rather than only say what would be done
        # @return [Array<String>] one block of lines for each bloated row, or the line that none is
        def call(confirm:)
          return ["nothing is bloated"] if @breaches.empty?

          @breaches.group_by(&:key).flat_map { |key, found| confirm ? act(key, found) : plan(key, found) }
        end

        private

        def plan(key, found)
          [*found.map { |breach| "bloated #{breach.line}" }, "would #{stopping(key)}yield #{key}: #{found.first.reason}"]
        end

        def act(key, found)
          [*found.map { |breach| "bloated #{breach.line}" }, stop(key), @launcher.yield_back(key, found.first.reason)].compact
        end

        def stopping(key) = session(key) ? "stop session #{session(key)}, then " : "(no running session: cannot stop, tell the owner) "

        def stop(key)
          id = session(key)
          return "cannot stop #{key}: tell the owner (no running session is recorded)" unless id

          @stopper.call(id)
          @launcher.check(key)
          "stopped session #{id}"
        rescue ConsoleCapture::Failure => e
          "cannot stop #{key}: tell the owner (#{e.message})"
        end

        def session(key)
          run = @runs[key]
          run[:session] if run && run[:status] == "started" && !run[:session].to_s.empty?
        end
      end
    end
  end
end
