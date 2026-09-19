require_relative "../runtime/registry"

module Hecks
  module Ports
    # An authenticated (issuer, subject) pair, resolved to the id of a stable
    # `Identity` — the other half of the same symmetry `Authorization`
    # already has for Governance: one adapter registry-wide answers this
    # port, resolved the same zero/one/many way, so an application never
    # has to name `Identity` directly to ask "who is this."
    #
    # Answers `nil` for a pair nothing has linked — the caller decides
    # what that means (refuse, prompt to register, whatever), the same
    # way `Authorization#holds_role?` answering `false` decides nothing
    # on its own.
    module IdentityResolution
      NAME = "identity_resolution".freeze

      module_function

      # Looks up the id of the identity an authenticated (issuer, subject) pair is linked to.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
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

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can resolve an identity"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
