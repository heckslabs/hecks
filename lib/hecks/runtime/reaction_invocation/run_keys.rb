require_relative "../../ports/identity_generation"

module Hecks
  module Runtime
    module ReactionInvocation
      # Gives a creating command a `run` key when a reaction names none, as the launcher does for a
      # typed command. The key comes from the identity port and rides in the command's arguments,
      # so the event records it and a replay re-dispatches the recorded value. Extended onto
      # {ReactionInvocation}.
      module RunKeys
        private

        # @param registry [Runtime::Registry] where the identity port is bound
        # @param command [#attributes] the creating command the reaction targets
        # @param facts [Hash{Symbol => Object}] the facts the reaction selected
        # @return [Hash{Symbol => Object}] `facts`, with a fresh `run` when the command requires one
        #   and none was given; unchanged when no identity adapter is bound
        def with_minted_run(registry, command, facts)
          return facts if facts.key?(:run) || !requires_run?(command)

          facts.merge(run: { value: Ports::IdentityGeneration.uuid(registry) })
        rescue WiringError
          facts
        end

        def requires_run?(command)
          command.attributes.any? { |attribute| attribute.name.to_sym == :run && !attribute.optional? }
        end
      end
    end
  end
end
