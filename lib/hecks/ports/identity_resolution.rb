require_relative "../runtime/registry"

module Hecks
  module Ports
    # Resolves an authenticated (issuer, subject) pair to a stable identity id.
    # One adapter registry-wide answers this port.
    module IdentityResolution
      NAME = "identity_resolution".freeze

      module_function

      # Looks up the id of the identity an authenticated (issuer, subject) pair is linked to.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param issuer [String] the OIDC issuer that authenticated the caller
      # @param subject [String] the OIDC subject the issuer vouches for
      # @return [String, nil] the linked identity's id, usable as an `actor_id` for
      #   `Ports::Authorization.holds_role?` — not an `Identity` record; nil if nothing has
      #   linked this pair
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def resolve(registry, issuer:, subject:)
        adapter(registry).resolve(registry, issuer: issuer, subject: subject)
      end

      # Finds the single adapter bound to this port, refusing an ambiguous wiring.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements this port,
      #   or the one that does has no Ruby implementation under `Hecks::Adapters`
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can resolve an identity" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
