# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What the Tickets world says about which sessions start without credentials: the
      # `session_credentials` verb, `scrub:` whether any is scrubbed and `keep:` the roles that keep
      # theirs. An undeclared verb, or `scrub: false`, scrubs none, so every session starts as
      # before.
      class CredentialSetting
        # The world verb that says which sessions start without credentials.
        VERB = "session_credentials"

        # The name `keep:` gives a run that names no agent, which runs `claude`'s default.
        DEFAULT = "default"

        # @param registry [Runtime::Registry, nil] whose Tickets world declares the verb
        def initialize(registry)
          @registry = registry
        end

        # @param agent [String, nil] the role a run's session starts as, nil for the default
        # @return [Boolean] whether the session starts without credentials
        def scrub?(agent)
          declared[:scrub] == true && !Array(declared[:keep]).map(&:to_s).include?(role(agent))
        end

        private

        def role(agent) = agent.to_s.empty? ? DEFAULT : agent.to_s

        def declared = @registry&.world("Tickets")&.for_verb(VERB) || {}
      end
    end
  end
end
