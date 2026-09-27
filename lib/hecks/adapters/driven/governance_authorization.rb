require "time"

module Hecks
  module Adapters
    # The `authorization` port, answered by dispatching queries against Governance's records
    # in the same registry. Only assignments with no `ends_at` count as live.
    module GovernanceAuthorization
      module_function

      # Reports whether `actor_id` holds a live grant of `role`.
      #
      # `as_of` and `scope` are opt-in: nil skips the matching check. `as_of` comes from the
      # caller, since the dispatch path must not read the clock (see `Ports::Clock`).
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param actor_id [String] the actor whose grants are checked
      # @param role [String, Symbol] the role name to look for
      # @param as_of [Integer, nil] Unix epoch seconds; a later (or unparseable) `starts_at` fails
      # @param scope [String, nil] the scope the caller acts in; nil skips the scope check
      # @return [Boolean] true if a live grant of `role` to `actor_id` passes both checks
      # @raise [Runtime::WiringError] unless exactly one chapter provides `"authorization"`
      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        rows = Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :assignments),
          actor_id: { value: actor_id.to_s }
        )

        rows.any? do |row|
          row[:role_name][:value] == role.to_s &&
            row[:ends_at].nil? &&
            in_scope?(row, scope) &&
            started?(row, as_of)
        end
      end

      # Without a `scope`, any live assignment for the role authorizes everywhere.
      #
      # @param row [Hash{Symbol => Object}] one `RoleAssignment` row as
      #   `Runtime::Dispatcher#query` returns it; `:scope` holds a `{value: String}` Hash
      # @param scope [String, nil] the scope to check against; nil accepts any scope
      # @return [Boolean] true if `scope` is nil, or the row's own scope matches it
      def in_scope?(row, scope)
        scope.nil? || row[:scope][:value] == scope.to_s
      end

      # `starts_at` is free text, so it is parsed with `Time.parse` rather than compared
      # lexically. Fails closed: an unparseable value counts as not yet started.
      #
      # @param row [Hash{Symbol => Object}] one `RoleAssignment` row as
      #   `Runtime::Dispatcher#query` returns it; `:starts_at` holds a `{value: String}` Hash
      # @param as_of [Integer, nil] Unix epoch seconds to compare against; nil accepts any row
      # @return [Boolean] true if `as_of` is nil, or the row's `starts_at` parses and is at or
      #   before `as_of`; false if `starts_at` does not parse as a time
      def started?(row, as_of)
        return true if as_of.nil?

        Time.parse(row[:starts_at][:value].to_s).to_i <= as_of
      rescue ArgumentError, TypeError
        false
      end

      # Answers whether one role may act as another.
      #
      # Read with `.any?` rather than trusting that the exact-pair lookup returns one row.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param from_role [String, Symbol] the role the caller holds, compared as a String
      # @param to_role [String, Symbol] the role the caller wants to act as, compared as a String
      # @return [Boolean] true if a live allowance lets `from_role` act as `to_role`
      # @raise [Runtime::WiringError] unless exactly one chapter provides `"authorization"`
      def authorized_as?(registry, from_role:, to_role:)
        rows = Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :transitions),
          from_role: { value: from_role.to_s }, to_role: { value: to_role.to_s }
        )

        rows.any? { |row| row[:ends_at].nil? }
      end

      # Returns the actor's live role name, or nil; any fallback is the caller's.
      #
      # @param registry [Runtime::Registry] the booted registry, to resolve the authorization
      #   provider's verb
      # @param actor_id [String] the actor to look up, compared as a String
      # @return [String, nil] the role name of the actor's first live (not ended) grant, or
      #   nil if it has none
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` are
      #   not exactly one (see `provided_verb`)
      def live_role_for(registry, actor_id:)
        rows = Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :assignments),
          actor_id: { value: actor_id.to_s }
        )

        live = rows.find { |row| row[:ends_at].nil? }
        live && live[:role_name][:value]
      end

      # Reads a verb from the one chapter that `provides "authorization"`; the runtime will
      # not choose between several (as in `Ports::Authorization.adapter`).
      #
      # @param registry [Runtime::Registry] the booted registry to search for the
      #   `"authorization"` provider
      # @param key [Symbol] which declared verb to read — `:assignments`, `:grant`, or
      #   `:transitions`
      # @return [String] the fully-qualified verb the loaded chapter provides for `key`
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` are
      #   not exactly one
      def provided_verb(registry, key)
        providers = registry.authorization_providers
        unless providers.size == 1
          raise Runtime::WiringError,
                "#{providers.size} loaded chapters provide \"authorization\"" \
                "#{" (#{providers.map(&:name).sort.join(', ')})" unless providers.empty?} — " \
                "a role lookup needs exactly one (framework members declaring it: " \
                "#{Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION).join(', ')})"
        end

        providers.first.provided_verb(Bluebook::Capabilities::AUTHORIZATION, key)
      end
    end
  end
end
