# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class RecipientCheck
      # The sessions registered by hand (`HandRun.register!`), read from the Agents registry by
      # run key. It only reads; a boot that holds no `HandRun` has none.
      class HandRuns
        # @param registry [Runtime::Registry, nil] whose Agents bluebook holds the `HandRun` rows
        # @param stand_in [#call, nil] answers each hand run's key with its `session:`, for specs
        def initialize(registry, stand_in = nil)
          @registry = registry
          @stand_in = stand_in
        end

        # @param run [String] the run key a message is addressed to
        # @return [String] the session registered under the key, empty when none is
        def session(run) = (@stand_in ? (@stand_in.call[run] || {})[:session] : read(run)).to_s

        # @return [Array<Hash{Symbol => String}>] each current registration's `run:`, `session:` and
        #   `role:`; a replaced one, archived as `<run>~<n>`, is left out
        def registered
          rows = @stand_in ? standing_rows : stored_rows
          rows.reject { |row| row[:run].include?("~") }
        end

        private

        def standing_rows
          @stand_in.call.map { |run, row| { run: run.to_s, session: row[:session].to_s, role: row[:role].to_s } }
        end

        def stored_rows
          aggregate = hand_run
          return [] unless aggregate

          @registry.repository("Agents", aggregate).all.map { |row| entry(row) }
        end

        def entry(row)
          { run: StartedWork.value(row, :run).to_s, session: StartedWork.value(row, :session).to_s,
            role: StartedWork.value(row, :role).to_s }
        end

        # The registration held under the key itself; an earlier one is archived as `<run>~<n>`.
        def read(run)
          aggregate = hand_run
          row = aggregate && @registry.repository("Agents", aggregate).find(run)
          row ? StartedWork.value(row, :session) : ""
        end

        def hand_run
          bluebook = @registry&.bluebook("Agents")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == "HandRun" }
        end
      end
    end
  end
end
