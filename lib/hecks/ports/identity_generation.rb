require_relative "../runtime/registry"
require_relative "../runtime/adapter_lookup"

module Hecks
  module Ports
    # Supplies the identity for a creating command with no natural key.
    # One adapter registry-wide implements it. Replay never calls it: the minted value is
    # already baked into the recorded step's args.
    module IdentityGeneration
      NAME = "identity_generation".freeze

      # What a stand-in is told it is answering in this port's place.
      ASKED = "a minted identity".freeze

      module_function

      # Mints a fresh identity value from the bound adapter.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [String] a newly minted identity: a random UUID from `SecureRandomIdentity`,
      #   or a decimal counter from the deterministic `SequentialIdentity` spec double
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def uuid(registry) = adapter(registry).uuid

      # Finds the single adapter bound to this port, or what `Runtime::AdapterLookup.standing_in`
      # has put in its place, as every other port's adapter is found.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [#uuid] the bound adapter, or the stand-in for it
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        raise Runtime::WiringError, wiring_refusal(implementations) unless implementations.size == 1

        Runtime::AdapterLookup.stand_in_for(NAME, ASKED) || registry.adapter_class(implementations.first.name)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can mint an identity" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
