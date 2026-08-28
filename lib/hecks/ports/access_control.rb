require_relative "../runtime/registry"

module Hecks
  module Ports
    # WHO CAN SIGN IN, AND WHAT ROLE DO THEY HOLD — the domain-specific
    # half of sign-in `Ports::Authentication` deliberately stays out of
    # (see that port's own header: it only ever talks to the external
    # provider, never this registry's own data). Resolved the same way
    # every other port here resolves its adapter: one adapter
    # registry-wide answers this, since an app has no reason to want a
    # different "who's allowed in" source per aggregate.
    #
    # Every domain shapes this differently — who its own "a person who
    # can sign in" aggregate is, what admits them, what grants them
    # access — so this port is pure delegation, same as every sibling
    # port. The one piece of this that IS generic (a live Governance
    # grant should win over whatever an aggregate's own role field
    # says) lives on `Ports::Authorization#live_role_for` instead —
    # a domain's adapter here calls that directly, rather than this
    # port re-deriving Governance-query logic another port already owns.
    module AccessControl
      NAME = "access_control"

      module_function

      def session_for_identity(registry, identity_id:)
        adapter(registry).session_for_identity(registry, identity_id: identity_id)
      end

      def provision(registry, email:, issuer:, subject:)
        adapter(registry).provision(registry, email: email, issuer: issuer, subject: subject)
      end

      def available_roles(registry)
        adapter(registry).available_roles(registry)
      end

      def grant(registry, email:, role:)
        adapter(registry).grant(registry, email: email, role: role)
      end

      def all_people(registry)
        adapter(registry).all_people(registry)
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can answer who's allowed in"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
