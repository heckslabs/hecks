require_relative "../runtime/registry"

module Hecks
  module Ports
    # Who can sign in and what role they hold: the domain-specific half of sign-in.
    # Pure delegation to the one adapter bound registry-wide; adapters that need a
    # live Governance grant call `Ports::Authorization#live_role_for`.
    module AccessControl
      NAME = "access_control".freeze

      module_function

      # Asks the domain's adapter for the session an already-resolved identity signs into.
      #
      # No adapter or spec double for this port ships in this repository, so every shape
      # below other than `registry` is adapter-defined: the port forwards it untouched.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param identity_id [Object] adapter-defined identity key, forwarded unchanged
      # @return [Object] adapter-defined session representation
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def session_for_identity(registry, identity_id:)
        adapter(registry).session_for_identity(registry, identity_id: identity_id)
      end

      # Admits a new person, in whatever way this domain's adapter defines admission.
      #
      # The keywords carry the names of a verified sign-in (`Ports::Authentication.verify`),
      # but nothing here wires the two together, so their shapes are adapter-defined.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param email [Object] adapter-defined, forwarded unchanged; the person's email
      # @param issuer [Object] adapter-defined, forwarded unchanged; the OIDC issuer
      # @param subject [Object] adapter-defined, forwarded unchanged; the OIDC subject
      # @return [Object] adapter-defined representation of the newly admitted person
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def provision(registry, email:, issuer:, subject:)
        adapter(registry).provision(registry, email: email, issuer: issuer, subject: subject)
      end

      # Asks the domain's adapter which roles it can grant.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Object] adapter-defined collection of grantable roles
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def available_roles(registry)
        adapter(registry).available_roles(registry)
      end

      # Grants a role to a person, by whatever means the domain's adapter records a grant.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
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
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
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
                "(#{implementations.map(&:name).sort.join(", ")}) — the runtime will not choose for you"
        end
      end
    end
  end
end
