require_relative "../runtime/registry"

module Hecks
  module Ports
    # An authenticated (issuer, subject) pair, resolved to a stable
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

      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param issuer [String] the OIDC issuer that authenticated the caller
      # @param subject [String] the OIDC subject the issuer vouches for
      # @return [Object, nil] the resolved Identity, or nil if this (issuer, subject) is unlinked
      def resolve(registry, issuer:, subject:)
        adapter(registry).resolve(registry, issuer: issuer, subject: subject)
      end

      # Finds the single adapter bound to this port.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Class] the adapter class implementing this port
      # @raise [Runtime::WiringError] if zero or more than one adapter implements it
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
