require "time"

module Hecks
  module Adapters
    # The `authorization` port, answered by dispatching queries against Governance's records
    # in the same registry. Which grants are live is Governance's own declaration, its two
    # `Live` queries; this reads them and decides nothing about liveness.
    module GovernanceAuthorization
      module_function

      # Reports whether `actor_id` holds a live grant of `role`. Liveness (not revoked, started
      # by `as_of`) and scope are the bluebook's Governance queries; this reads them and decides
      # neither. `as_of` defaults to the bound clock, so a later grant does not count yet.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param actor_id [String] the actor whose grants are checked
      # @param role [String, Symbol] the role name to look for
      # @param as_of [Integer, nil] Unix epoch seconds the grant must have started by; nil reads
      #   the clock port
      # @param scope [String, nil] the scope the caller acts in; nil accepts a grant for any scope
      # @return [Boolean] true if a live grant of `role` to `actor_id` passes both checks
      # @raise [Runtime::WiringError] unless exactly one bluebook provides `"authorization"`
      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        at = as_of_text(registry, as_of)
        rows = if scope.nil?
                 live_assignments(registry, actor_id, at)
               else
                 live_scoped_assignments(registry, actor_id, scope, at)
               end
        rows.any? { |row| row[:role_name][:value] == role.to_s }
      end

      # The `as_of` a query compares `starts_at` against: UTC `YYYY-MM-DDTHH:MM:SSZ`, which sorts
      # with the stored UTC dates and date-times as text.
      #
      # @param registry [Runtime::Registry] the booted registry, to read the clock port
      # @param as_of [Integer, nil] Unix epoch seconds; nil reads the clock port
      # @return [String] the UTC instant as a Timestamp value
      def as_of_text(registry, as_of)
        seconds = as_of || Ports::Clock.now(registry)
        Time.at(seconds).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      # Answers whether one role may act as another.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param from_role [String, Symbol] the role the caller holds, compared as a String
      # @param to_role [String, Symbol] the role the caller wants to act as, compared as a String
      # @return [Boolean] true if a live allowance lets `from_role` act as `to_role`
      # @raise [Runtime::WiringError] unless exactly one bluebook provides `"authorization"`
      def authorized_as?(registry, from_role:, to_role:, as_of: nil)
        Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :live_transitions),
          from_role: { value: from_role.to_s }, to_role: { value: to_role.to_s },
          as_of: { value: as_of_text(registry, as_of) }
        ).any?
      end

      # Returns the actor's live role name, or nil; any fallback is the caller's.
      #
      # @param registry [Runtime::Registry] the booted registry, to resolve the authorization
      #   provider's verb
      # @param actor_id [String] the actor to look up, compared as a String
      # @return [String, nil] the role name of the actor's first live grant, or nil if it has none
      # @raise [Runtime::WiringError] if the loaded bluebooks providing `"authorization"` are
      #   not exactly one (see `provided_verb`)
      def live_role_for(registry, actor_id:)
        live = live_assignments(registry, actor_id, as_of_text(registry, nil)).first
        live && live[:role_name][:value]
      end

      # The rows the provider's `live_assignments` query answers for one actor.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param actor_id [String] the actor, compared as a String
      # @param as_of [String] the UTC Timestamp the grant must have started by
      # @return [Array<Hash{Symbol => Object}>] the actor's grants that have not ended and have started
      def live_assignments(registry, actor_id, as_of)
        Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :live_assignments),
          actor_id: { value: actor_id.to_s }, as_of: { value: as_of }
        )
      end

      # The rows the provider's `live_scoped_assignments` query answers for one actor and scope.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param actor_id [String] the actor, compared as a String
      # @param scope [String, Symbol] the scope the grant must have been made for
      # @param as_of [String] the UTC Timestamp the grant must have started by
      # @return [Array<Hash{Symbol => Object}>] the actor's live grants made for that scope
      def live_scoped_assignments(registry, actor_id, scope, as_of)
        Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :live_scoped_assignments),
          actor_id: { value: actor_id.to_s }, scope: { value: scope.to_s }, as_of: { value: as_of }
        )
      end

      # Reads a verb from the one bluebook that `provides "authorization"`; the runtime will
      # not choose between several (as in `Ports::Authorization.adapter`).
      #
      # @param registry [Runtime::Registry] the booted registry to search for the
      #   `"authorization"` provider
      # @param key [Symbol] which declared verb to read: `:live_assignments`, `:live_transitions`,
      #   `:grant`, or one of the history queries `:assignments` and `:transitions`
      # @return [String] the fully-qualified verb the loaded bluebook provides for `key`
      # @raise [Runtime::WiringError] if the loaded bluebooks providing `"authorization"` are
      #   not exactly one
      def provided_verb(registry, key)
        providers = registry.authorization_providers
        unless providers.size == 1
          raise Runtime::WiringError,
                "#{providers.size} loaded bluebooks provide \"authorization\"" \
                "#{" (#{providers.map(&:name).sort.join(", ")})" unless providers.empty?} — " \
                "a role lookup needs exactly one (framework members declaring it: " \
                "#{Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION).join(", ")})"
        end

        providers.first.provided_verb(Bluebook::Capabilities::AUTHORIZATION, key)
      end
    end
  end
end
