require_relative "../runtime/registry"

module Hecks
  module Ports
    # Two yes/no questions and one value an application asks before
    # binding a caller — resolved the same way `Ports::IdentityGeneration`
    # resolves its own adapter: one adapter registry-wide answers this
    # port, not a per-aggregate binding, since a domain has no reason to
    # want a different authorization source per aggregate. What answers
    # it is deliberately not named here — the governance-backed adapter
    # is one implementation, not the only possible one, the same way
    # `SequentialIdentity` and `SecureRandomIdentity` are two
    # implementations of `identity_generation`.
    #
    # A caller decides what to do with the answer — dispatch under that
    # role, refuse, log, prefer it over some other fallback value — this
    # only answers the question asked. Nothing here binds a
    # `Runtime::Caller`.
    #
    # `CommandRules::Authorization#refuse_role_mismatch` calls `holds_role?`
    # directly, once a caller binds an `actor_id` and the command's domain
    # has Governance attached (see that rule's own header). `spec/
    # act_as_spec.rb` remains the precedent for the other shape — two
    # separate registries, queried directly by name — for whenever
    # Governance is not in the same boot as the caller; this port is the
    # same questions asked through one adapter when it is.
    module Authorization
      NAME = "authorization".freeze

      module_function

      # Answers whether an actor holds a live (not ended) grant of a role.
      #
      # @param registry [Runtime::Registry] the booted registry, used to resolve the adapter
      #   and handed on to it
      # @param actor_id [String] the actor whose grants are checked
      # @param role [String, Symbol] the role name to look for, compared as a String
      # @param as_of [Integer, nil] Unix epoch seconds (from `Ports::Clock.now`); a grant whose
      #   `starts_at` is later, or does not parse as a time, does not count. nil skips the
      #   `starts_at` check entirely
      # @param scope [String, nil] the scope the caller acts in; only a grant made for that
      #   scope counts. nil skips the scope check, so a grant in any scope counts
      # @return [Boolean] true if at least one live grant of `role` to `actor_id` passes the
      #   `as_of` and `scope` checks
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`), or the governance-backed adapter finds no single loaded chapter
      #   providing `"authorization"`
      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        adapter(registry).holds_role?(registry, actor_id: actor_id, role: role, as_of: as_of, scope: scope)
      end

      # Answers whether one role may act as another.
      #
      # @param registry [Runtime::Registry] the booted registry, used to resolve the adapter
      #   and handed on to it
      # @param from_role [String, Symbol] the role the caller holds, compared as a String
      # @param to_role [String, Symbol] the role the caller wants to act as, compared as a
      #   String
      # @return [Boolean] true if a live (not ended) allowance lets `from_role` act as
      #   `to_role`
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`), or the governance-backed adapter finds no single loaded chapter
      #   providing `"authorization"`
      def authorized_as?(registry, from_role:, to_role:)
        adapter(registry).authorized_as?(registry, from_role: from_role, to_role: to_role)
      end

      # Looks up the role an actor holds right now, rather than checking a guessed one.
      #
      # @param registry [Runtime::Registry] the booted registry, used to resolve the adapter
      #   and handed on to it
      # @param actor_id [String] the actor to look up
      # @return [String, nil] the role name of the actor's first live (not ended) grant, or
      #   nil if it has none; the caller supplies any fallback
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`), or the governance-backed adapter finds no single loaded chapter
      #   providing `"authorization"`
      def live_role_for(registry, actor_id:)
        adapter(registry).live_role_for(registry, actor_id: actor_id)
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
