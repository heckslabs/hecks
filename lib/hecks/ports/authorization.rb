require_relative "../runtime/registry"

module Hecks
  module Ports
    # TWO YES/NO QUESTIONS AND ONE VALUE an application asks BEFORE
    # binding a caller — resolved the same way `Ports::IdentityGeneration`
    # resolves its own adapter: one adapter registry-wide answers this
    # port, not a per-aggregate binding, since a domain has no reason to
    # want a different authorization source per aggregate. What answers
    # it is deliberately not named here — the governance-backed adapter
    # is one implementation, not the only possible one, the same way
    # `SequentialIdentity` and `SecureRandomIdentity` are two
    # implementations of `identity_generation`.
    #
    # A caller decides what to DO with the answer — dispatch under that
    # role, refuse, log, prefer it over some other fallback value — this
    # only answers the question asked. Nothing here binds a
    # `Runtime::Caller`.
    #
    # STALE AS OF THE `as_of`/`scope` split below, this used to also say
    # nothing here is consulted by `CommandRules::Authorization` — it now
    # is: `refuse_role_mismatch` calls `holds_role?` directly, once a
    # caller binds an `actor_id` and the command's domain has Governance
    # attached (see that rule's own header). `spec/act_as_spec.rb`
    # remains the precedent for the OTHER shape — two separate
    # registries, queried directly by name — for whenever Governance is
    # not in the same boot as the caller; this port is the same
    # questions asked through one adapter when it is.
    module Authorization
      NAME = "authorization"

      module_function

      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        adapter(registry).holds_role?(registry, actor_id: actor_id, role: role, as_of: as_of, scope: scope)
      end

      def authorized_as?(registry, from_role:, to_role:)
        adapter(registry).authorized_as?(registry, from_role: from_role, to_role: to_role)
      end

      def live_role_for(registry, actor_id:)
        adapter(registry).live_role_for(registry, actor_id: actor_id)
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can answer a role check"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
