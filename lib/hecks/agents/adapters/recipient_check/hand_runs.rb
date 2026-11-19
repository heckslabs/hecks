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

        private

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
