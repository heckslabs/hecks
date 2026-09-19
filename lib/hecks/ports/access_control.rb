require_relative "../runtime/registry"

module Hecks
  module Ports
    # Who can sign in, and what role do they hold — the domain-specific
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
    # port. The one piece of this that is generic (a live Governance
    # grant should win over whatever an aggregate's own role field
    # says) lives on `Ports::Authorization#live_role_for` instead —
    # a domain's adapter here calls that directly, rather than this
    # port re-deriving Governance-query logic another port already owns.
    module AccessControl
      NAME = "access_control".freeze

      module_function

      # Looks up the session an already-resolved identity is signed into.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param identity_id [String] the identity to look up
      # @return [Object, nil] the adapter's own session representation, or nil if none
      def session_for_identity(registry, identity_id:)
        adapter(registry).session_for_identity(registry, identity_id: identity_id)
      end

      # Admits a new person, in whatever way this domain's adapter defines admission.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param email [String] the person's email
      # @param issuer [String] the OIDC issuer that authenticated them
      # @param subject [String] the OIDC subject the issuer vouches for
      # @return [Object] the adapter's own representation of the newly-admitted person
      def provision(registry, email:, issuer:, subject:)
        adapter(registry).provision(registry, email: email, issuer: issuer, subject: subject)
      end

      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Array] the roles this domain's adapter can grant
      def available_roles(registry)
        adapter(registry).available_roles(registry)
      end

      # Grants a role to an already-admitted person.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param email [String] the person to grant the role to
      # @param role [Symbol, String] the role to grant, one of `available_roles`
      # @return [Object] the adapter's own representation of the grant
      def grant(registry, email:, role:)
        adapter(registry).grant(registry, email: email, role: role)
      end

      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Array] every person this domain's adapter knows about
      def all_people(registry)
        adapter(registry).all_people(registry)
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
