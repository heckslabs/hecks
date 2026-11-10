# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class MainIntegration
      # What one step of an advance came to, as the step's own `Integration` record holds it: a
      # boarding the train took names what it answered (the pull request or the pushed commit),
      # and a step that parked its run for a person names the refusal. Reads only.
      class Outcome
        # @param registry [Runtime::Registry] the booted registry whose `Integration` rows are read
        def initialize(registry)
          @registry = registry
        end

        # @param command [String] the step's command: `Verify`, `Board` or `Observe`
        # @param stage [String, nil] the stage the step left its run in
        # @param key [String] the step's `Integration` record
        # @return [String] `"; boarded <answer>"`, `"; needs_human: <refusal>"`, or empty
        def of(command, stage, key)
          return "; needs_human: #{field(key, :refusal)}" if stage == "needs_human"
          return "; boarded #{field(key, :report)}" if command == "Board" && stage == "pushed"

          ""
        end

        private

        def field(key, name)
          record = repository&.find(key)
          record ? StartedWork.value(record, name).to_s : "no record of #{key}"
        end

        def repository
          aggregate = @registry.bluebook("Hecks")&.aggregates&.find { |candidate| candidate.hecks_name == "Integration" }
          aggregate && @registry.repository("Hecks", aggregate)
        end
      end
    end
  end
end
