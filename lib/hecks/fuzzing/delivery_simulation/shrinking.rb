# frozen_string_literal: true

require_relative "../shrinker"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # Shrinks a failing schedule in two passes of the one shrinker: first the agents that take
      # part, then the steps of those that are left.
      #
      # A step-first shrink keeps nearly every agent for a long time, since each agent has several
      # steps and a replay costs what its agents cost. Dropping whole agents first leaves the
      # step pass a schedule of a few agents.
      module Shrinking
        module_function

        # @param schedule [Array<Hash>] a schedule whose replay finds a divergence
        # @param budget [Integer, nil] the most candidates each pass may replay
        # @yieldparam candidate [Array<Hash>] a schedule to replay
        # @yieldreturn [Boolean] whether it still breaks the same invariant
        # @return [Array<Hash>] the shrunk schedule
        def call(schedule, budget: nil, &reproduces)
          few = fewest_agents(schedule, budget, &reproduces)
          Shrinker.call(few, budget: budget, &reproduces).steps
        end

        # The schedule with every agent dropped whose steps the finding does not need.
        def fewest_agents(schedule, budget)
          names = schedule.filter_map { |step| agent_of(step) }.uniq.map { |name| { "verb" => name } }
          return schedule if names.empty?

          kept = Shrinker.call(names, budget: budget) { |candidate| yield only(schedule, candidate) }.steps
          only(schedule, kept)
        end

        # The steps of `schedule` that are faults or belong to an agent in `kept`.
        def only(schedule, kept)
          names = kept.map { |step| step["verb"] }
          schedule.select { |step| agent_of(step).nil? || names.include?(agent_of(step)) }
        end

        # @param step [Hash] a step of a schedule
        # @return [String, nil] the agent an `advance` step names
        def agent_of(step)
          step = step.transform_keys(&:to_s)
          return unless step["verb"] == "advance"

          (step["args"] || {}).transform_keys(&:to_s)["agent"]
        end
      end
    end
  end
end
