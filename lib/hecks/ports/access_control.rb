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

      # Asks the domain's adapter for the session an already-resolved identity signs into.
      #
      # No adapter or spec double for this port ships in this repository, so every shape
      # below other than `registry` is adapter-defined: the port forwards it untouched.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
      # @param identity_id [Object] adapter-defined identity key, forwarded unchanged
      # @return [Object] adapter-defined session representation
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def session_for_identity(registry, identity_id:)
        adapter(registry).session_for_identity(registry, identity_id: identity_id)
      end

      # Admits a new person, in whatever way this domain's adapter defines admission.
      #
      # The keywords carry the names of a verified sign-in (`Ports::Authentication.verify`
      # answers `issuer`, `subject` and `email`), but nothing in this repository wires the
      # two together, so their shapes here are adapter-defined.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
      # @param email [Object] adapter-defined, forwarded unchanged; the person's email
      # @param issuer [Object] adapter-defined, forwarded unchanged; the OIDC issuer that
      #   authenticated the person
      # @param subject [Object] adapter-defined, forwarded unchanged; the OIDC subject the
      #   issuer vouches for
      # @return [Object] adapter-defined representation of the newly admitted person
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def provision(registry, email:, issuer:, subject:)
        adapter(registry).provision(registry, email: email, issuer: issuer, subject: subject)
      end

      # Asks the domain's adapter which roles it can grant.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
      # @return [Object] adapter-defined collection of grantable roles
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def available_roles(registry)
        adapter(registry).available_roles(registry)
      end

      # Grants a role to a person, by whatever means the domain's adapter records a grant.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
      # @param email [Object] adapter-defined, forwarded unchanged; the person receiving the role
      # @param role [Object] adapter-defined, forwarded unchanged; the role to grant
      # @return [Object] adapter-defined representation of the grant
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def grant(registry, email:, role:)
        adapter(registry).grant(registry, email: email, role: role)
      end

      # Lists every person the domain's adapter knows about.
      #
      # @param registry [Runtime::Registry] the booted registry — resolves the adapter and is
      #   forwarded to it as well
      # @return [Object] adapter-defined collection of people
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def all_people(registry)
        adapter(registry).all_people(registry)
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
