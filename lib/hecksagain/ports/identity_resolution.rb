require_relative "../runtime/registry"

module Hecksagain
  module Ports
    # AN AUTHENTICATED (issuer, subject) PAIR, RESOLVED TO A STABLE
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
      NAME = "identity_resolution"

      module_function

      def resolve(registry, issuer:, subject:)
        adapter(registry).resolve(registry, issuer: issuer, subject: subject)
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
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
