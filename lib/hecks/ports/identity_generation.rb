require_relative "../runtime/registry"

module Hecks
  module Ports
    # Supplies the identity for a creating command with no natural key.
    # One adapter registry-wide implements it. Replay never calls it: the minted value is
    # already baked into the recorded step's args.
    module IdentityGeneration
      NAME = "identity_generation".freeze

      module_function

      # Mints a fresh identity value from the bound adapter.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [String] a newly minted identity: a random UUID from `SecureRandomIdentity`,
      #   or a decimal counter from the deterministic `SequentialIdentity` spec double
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def uuid(registry) = adapter(registry).uuid

      # Finds the single adapter bound to this port.
      #
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can mint an identity"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
