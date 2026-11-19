# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Dispatching
      # Says why the settle left a started work item where it is, read from its run's recorded
      # state. It names a state the AgentRun bluebook already decided and decides nothing itself.
      class SettleStanding
        # @param grace [Integer] seconds after its start that a run's session is read as unknown
        # @param clock [#call] answers the time, for the grace
        # @param in_flight [#call] answers whether a work item's landing job is running
        def initialize(grace:, clock:, in_flight:)
          @grace = grace
          @clock = clock
          @in_flight = in_flight
        end

        # @param key [String] the started work item
        # @param run [Hash, nil] its run's state, as {WorkItems#runs} reads it
        # @return [String] the line that says the item was left, and why
        def line(key, run) = "left #{key}: #{why(key, run)}"

        # @param run [Hash] a run's state
        # @return [Boolean] whether the run started too recently to say how its session ended; a
        #   run with no recorded start counts as old
        def young?(run)
          @clock.call - Time.parse(run[:started_at].to_s) < @grace
        rescue ArgumentError
          false
        end

        private

        def why(key, run)
          return "no run is recorded for it" unless run
          return session(run) if run[:status] == "started"
          return ended(key, run) if run[:status] == "finished"

          "its run is #{run[:status]}"
        end

        def session(run)
          case run[:condition]
          when "working" then "its session is still working#{since(run)}"
          when "blocked" then "its session is blocked on a person#{since(run, "its run started")}"
          else "its session has not said how it is yet#{since(run)}"
          end
        end

        # The run's recorded start, which the blocked line names because no block time is recorded.
        def since(run, words = "started")
          started = run[:started_at].to_s
          started.empty? ? "" : " (#{words} #{started})"
        end

        def ended(key, run)
          return "its session ended #{run[:condition]} under the #{@grace}s grace; read again next settle" if young?(run)
          return "its landing job is running; the landing finishes it or plans it again" if @in_flight.call(key)

          "its run is finished"
        end
      end
    end
  end
end
