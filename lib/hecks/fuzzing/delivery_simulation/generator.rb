# frozen_string_literal: true

require_relative "world"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # Draws a schedule from a seed: every agent begins once, in a shuffled order, and then
      # turns and faults are drawn at random.
      #
      # The same seed, agent count and step count give the same schedule.
      module Generator
        module_function

        # @param seed [Integer] the seed every draw comes from
        # @param agents [Integer] how many agents take part
        # @param steps [Integer, nil] how many steps follow the opening; four an agent when nil
        # @param fault_rate [Float] the share of those steps that are faults
        # @return [Array<Hash>] the schedule, in the shrinker's step shape
        def call(seed:, agents: 100, steps: nil, fault_rate: 0.05)
          random = Random.new(seed)
          names = Array.new(agents) { |index| format("a%03d", index + 1) }
          opening = names.shuffle(random: random).map { |name| advance(name) }
          opening + Array.new(steps || (agents * 4)) { draw(random, names, fault_rate) }
        end

        # @param agent [String] the agent that takes a turn
        # @return [Hash] the step
        def advance(agent) = { "verb" => "advance", "args" => { "agent" => agent } }

        # @param kind [String] a key of `World::FAULTS`
        # @return [Hash] the step
        def fault(kind) = { "verb" => "fault", "args" => { "kind" => kind } }

        def draw(random, names, fault_rate)
          return fault(World::FAULTS.keys.sample(random: random)) if random.rand < fault_rate

          advance(names.sample(random: random))
        end
      end
    end
  end
end
