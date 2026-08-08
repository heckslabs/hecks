require_relative "../runtime/registry"

module Hecksagain
  module Ports
    # TWO YES/NO QUESTIONS an application asks BEFORE binding a caller —
    # resolved the same way `Ports::IdentityGeneration` resolves its own
    # adapter: one adapter registry-wide answers this port, not a
    # per-aggregate binding, since a domain has no reason to want a
    # different authorization source per aggregate. What answers it is
    # deliberately not named here — the governance-backed adapter is one
    # implementation, not the only possible one, the same way
    # `SequentialIdentity` and `SecureRandomIdentity` are two
    # implementations of `identity_generation`.
    #
    # A caller decides what to DO with the answer — dispatch under that
    # role, refuse, log — this only answers the yes/no question. Nothing
    # here binds a `Runtime::Caller`, and nothing here is consulted by
    # `CommandRules::Authorization`: that rule still only compares an
    # ALREADY-BOUND caller's role against a command's, the same as it
    # always has. `spec/act_as_spec.rb` remains the precedent for the
    # OTHER shape — two separate registries, queried directly by name —
    # for whenever Governance is not in the same boot as the caller;
    # this port is the same two questions asked through one adapter
    # when it is.
    module Authorization
      NAME = "authorization"

      module_function

      def holds_role?(registry, actor_id:, role:)
        adapter(registry).holds_role?(registry, actor_id: actor_id, role: role)
      end

      def authorized_as?(registry, from_role:, to_role:)
        adapter(registry).authorized_as?(registry, from_role: from_role, to_role: to_role)
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
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
