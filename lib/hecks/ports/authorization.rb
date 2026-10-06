require_relative "../runtime/registry"

module Hecks
  module Ports
    # Role questions an application asks before binding a caller. One adapter registry-wide
    # answers them; it only answers, and never binds a `Runtime::Caller`.
    module Authorization
      NAME = "authorization".freeze

      module_function

      # Answers whether an actor holds a live (not ended) grant of a role.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param actor_id [String] the actor whose grants are checked
      # @param role [String, Symbol] the role name to look for, compared as a String
      # @param as_of [Integer, nil] Unix epoch seconds (from `Ports::Clock.now`); a grant whose
      #   `starts_at` is later, or does not parse as a time, does not count. nil skips the check
      # @param scope [String, nil] only a grant made for this scope counts; nil counts any scope
      # @return [Boolean] true if at least one live grant of `role` to `actor_id` passes
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter,
      #   or the governance-backed adapter finds no single chapter providing `"authorization"`
      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        adapter(registry).holds_role?(registry, actor_id: actor_id, role: role, as_of: as_of, scope: scope)
      end

      # Answers whether one role may act as another.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param from_role [String, Symbol] the role the caller holds, compared as a String
      # @param to_role [String, Symbol] the role the caller wants to act as, compared as a
      #   String
      # @return [Boolean] true if a live (not ended) allowance lets `from_role` act as
      #   `to_role`
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter,
      #   or the governance-backed adapter finds no single loaded chapter providing
      #   `"authorization"`
      def authorized_as?(registry, from_role:, to_role:)
        adapter(registry).authorized_as?(registry, from_role: from_role, to_role: to_role)
      end

      # Looks up the role an actor holds right now.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param actor_id [String] the actor to look up
      # @return [String, nil] the role name of the actor's first live (not ended) grant, or
      #   nil if it has none; the caller supplies any fallback
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter,
      #   or the governance-backed adapter finds no single loaded chapter providing
      #   `"authorization"`
      def live_role_for(registry, actor_id:)
        adapter(registry).live_role_for(registry, actor_id: actor_id)
      end

      # Finds the single adapter bound to this port.
      #
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — nothing can answer a role check" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
