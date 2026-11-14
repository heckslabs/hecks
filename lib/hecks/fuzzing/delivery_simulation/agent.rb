# frozen_string_literal: true

require_relative "../../runtime/errors"

module Hecks
  module Fuzzing
    class DeliverySimulation
      # One simulated agent: it commits on a branch of its own, lands it, boards the train and
      # watches its boarding, as an operator's session does.
      #
      # It dispatches the real commands on the booted runtime. A command the bluebook refuses is
      # the bluebook's answer, not a failure of the agent.
      class Agent
        # How often an agent reads a boarding that is still queued.
        WATCHES = 2

        # @param runtime [Runtime::Dispatcher] the booted runtime the commands go to
        # @param world [World] the world this replay runs in
        # @param name [String] the agent's name
        def initialize(runtime, world, name)
          @runtime = runtime
          @world = world
          @name = name
        end

        # @return [String] the run key of this agent's landing and of its boarding
        def run_key = "#{@world.tag}-#{@name}"

        # Runs the agent to its end. It dispatches with no stated caller, as a launcher's own
        # process does.
        #
        # @return [void]
        def run
          @world.repository.branch(branch)
          dispatch("Delivery::Landing.Land", branch: { value: branch }, checkout: { value: "/sim" }, confirm: yes)
          dispatch("Hecks::SendTrain.Board", confirm: yes)
          WATCHES.times { dispatch("Hecks::SendTrain.Watch") if waiting? }
          nil
        end

        private

        def branch = "work/#{@name}"

        def yes = { value: true }

        def dispatch(verb, **args)
          @runtime.dispatch_flat(verb, run: { value: run_key }, **args)
        rescue *Runtime::DOMAIN_REFUSALS
          nil
        end

        def waiting?
          boarding = @runtime.query("Hecks::SendTrain.Outcome", run: { value: run_key }).first
          boarding && boarding[:status] == "queued"
        end
      end
    end
  end
end
