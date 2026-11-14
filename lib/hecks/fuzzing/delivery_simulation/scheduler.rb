# frozen_string_literal: true

module Hecks
  module Fuzzing
    class DeliverySimulation
      # Plays a schedule: each agent runs in a Fiber of its own, and a step lets one of them run
      # until it next gives up its turn.
      #
      # A schedule is a list of steps in the shrinker's shape. `advance` names an agent, `fault`
      # names a kind the world knows. An agent takes part from the first step that names it, and
      # when the steps run out every agent that began is run to its end in name order, so any
      # sublist of a schedule is itself a schedule and replays the same way every time.
      class Scheduler
        # What gives up an agent's turn, for the world to call.
        PAUSE = -> { Fiber.yield }

        # @return [Array<String>] the agents that began, in the order they began
        attr_reader :agents

        # @param world [World] the world faults are switched in
        # @yieldparam agent [String] the agent to run, inside its own Fiber
        def initialize(world, &program)
          @world = world
          @program = program
          @fibers = {}
          @agents = []
        end

        # @param schedule [Array<Hash>] the steps to play
        # @return [void]
        def play(schedule)
          schedule.each { |step| take(step.transform_keys(&:to_s)) }
          @agents.sort.each { |agent| advance(agent) while @fibers[agent].alive? }
          nil
        end

        private

        def take(step)
          args = (step["args"] || {}).transform_keys(&:to_s)
          case step["verb"]
          when "advance" then advance(args["agent"].to_s)
          when "fault"   then @world.fault(args["kind"])
          end
        end

        def advance(agent)
          return if agent.empty?

          fiber = (@fibers[agent] ||= begin_agent(agent))
          fiber.resume if fiber.alive?
        end

        def begin_agent(agent)
          @agents << agent
          Fiber.new { @program.call(agent) }
        end
      end
    end
  end
end
