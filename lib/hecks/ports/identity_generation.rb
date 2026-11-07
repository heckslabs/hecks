require_relative "../runtime/registry"

module Hecks
  module Ports
    # Supplies the identity for a creating command with no natural key.
    # One adapter registry-wide implements it. Replay never calls it: the minted value is
    # already baked into the recorded step's args.
    module IdentityGeneration
      NAME = "identity_generation".freeze

      @stand_in = nil

      module_function

      # Answers every identity request with `stand_in` instead of the bound adapter while the
      # block runs, for a caller that needs the ids to be known in advance (a conformance replay
      # scripts them so both engines mint the same ones).
      #
      # @param stand_in [#uuid] the object that mints instead of the adapter
      # @yield the work to run with the stand-in in place
      # @return [Object] what the block answers
      def standing_in(stand_in)
        previous = @stand_in
        @stand_in = stand_in
        yield
      ensure
        @stand_in = previous
      end

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
        return @stand_in if @stand_in

        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
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
