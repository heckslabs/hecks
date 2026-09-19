require "time"

module Hecks
  module Adapters
    # **The `authorization` port, fulfilled by governance** — same registry,
    # same boot, so "ask Governance" is a dispatch against records
    # already sitting in the store this adapter is handed, not a bridge
    # to a second runtime. `Runtime::Dispatcher.new(registry)` is cheap
    # to build fresh per call (`Registry#capability_graph`'s own
    # neighbor, `#repository`, does the same kind of on-demand build) —
    # nothing here holds one across calls, so there is no boot-order
    # dependency on when Governance's bluebook loads relative to this
    # adapter, only that it has by the time `holds_role?` is called.
    #
    # An active assignment, not merely an ended one : `RoleAssignment`
    # answers with every assignment an actor has ever held, live or
    # ended (`AssignmentsForActor`'s own description), and leaves
    # `ends_at` for the caller to read, the same deferral
    # `Governance::RoleTransition.Allowed` makes for the same reason.
    # This is that caller.
    module GovernanceAuthorization
      module_function

      # Answers whether an actor holds a live grant of a role, querying Governance's own
      # assignments read model.
      #
      # `as_of` and `scope` are both optional, same opt-in shape
      # `refuse_role_mismatch` already gives `actor_id` itself — an
      # unbound `as_of` skips the `starts_at` check and an unbound
      # `scope` skips the `scope` check, exactly the behavior before
      # either existed. Neither is fetched here: `as_of` arrives already
      # resolved from `Ports::Clock.now`, called by the caller at the
      # door, never by this adapter — see `Ports::Clock`'s own header
      # for why the dispatch path must not consult the clock itself.
      #
      # @param registry [Runtime::Registry] the booted registry, queried for the single
      #   loaded chapter providing `"authorization"`
      # @param actor_id [String] the actor whose grants are checked, compared as a String
      # @param role [String, Symbol] the role name to look for, compared as a String
      # @param as_of [Integer, nil] Unix epoch seconds; a grant whose `starts_at` is later, or
      #   does not parse as a time, does not count. nil skips the `starts_at` check
      # @param scope [String, Symbol, nil] the scope the caller acts in, compared as a String;
      #   only a grant made for that scope counts. nil skips the scope check
      # @return [Boolean] true if at least one live (not ended) grant of `role` to `actor_id`
      #   passes the `as_of` and `scope` checks
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` do
      #   not number exactly one
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

      # Checks whether an assignment row was granted for the scope a caller names, or passes
      # unconditionally when the caller names none.
      #
      # `scope` unchecked when not stated, same as every other opt-in
      # field here — a caller that never says which scope it is acting
      # in gets the pre-scope behavior: any live assignment for the role
      # authorizes, everywhere. A caller that does state one only
      # authorizes against an assignment granted for that scope.
      #
      # @param row [Hash] one assignment row from the `assignments` verb's query result;
      #   `row[:scope][:value]` is read
      # @param scope [String, Symbol, nil] the scope to require, compared as a String; nil
      #   skips the check
      # @return [Boolean] true when `scope` is nil or matches the row's own scope
      def in_scope?(row, scope)
        scope.nil? || row[:scope][:value] == scope.to_s
      end

      # Checks whether an assignment row has already started as of a given time, or passes
      # unconditionally when no time is given.
      #
      # `starts_at` is a free-text string in the bluebook (`Timestamp`'s
      # only invariant is "present", not any particular format) — parsed
      # here with `Time.parse` rather than compared lexically, since
      # nothing guarantees every caller writes it zero-padded ISO 8601.
      # Fails closed : a `starts_at` that does not parse is treated as
      # not-yet-started rather than silently ignored, the same direction
      # every other check in this method already fails.
      #
      # @param row [Hash] one assignment row from the `assignments` verb's query result;
      #   `row[:starts_at][:value]` is read
      # @param as_of [Integer, nil] Unix epoch seconds to compare against; nil skips the check
      # @return [Boolean] true when `as_of` is nil, or the row's own `starts_at` parses and is
      #   no later than `as_of`; false when it does not parse or is later
      def started?(row, as_of)
        return true if as_of.nil?

        Time.parse(row[:starts_at][:value].to_s).to_i <= as_of
      rescue ArgumentError, TypeError
        false
      end

      # Answers whether one role may act as another, querying Governance's own transitions
      # read model.
      #
      # **The other half** — may role X act as role Y. `RoleTransition.Allowed`
      # is identified by the exact pair, so at most one row ever comes
      # back ; still read as `.any?` rather than trusting that structurally,
      # the same defensiveness `holds_role?` already has to have anyway
      # since `AssignmentsForActor` can return several.
      #
      # @param registry [Runtime::Registry] the booted registry, queried for the single
      #   loaded chapter providing `"authorization"`
      # @param from_role [String, Symbol] the role the caller holds, compared as a String
      # @param to_role [String, Symbol] the role the caller wants to act as, compared as a
      #   String
      # @return [Boolean] true if a live (not ended) allowance lets `from_role` act as `to_role`
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` do
      #   not number exactly one
      def authorized_as?(registry, from_role:, to_role:)
        rows = Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :transitions),
          from_role: { value: from_role.to_s }, to_role: { value: to_role.to_s }
        )

        rows.any? { |row| row[:ends_at].nil? }
      end

      # Looks up the role an actor holds right now, querying the same assignments read
      # model `holds_role?` does.
      #
      # The role itself, not just a yes/no about one — the same
      # `AssignmentsForActor` query `holds_role?` runs, just returning
      # the live (non-revoked) row's `role_name` instead of comparing it
      # against a caller-supplied guess. `nil` for no live assignment at
      # all — the caller's own fallback (an aggregate's own role field,
      # a default) is domain-specific and does not belong here.
      #
      # @param registry [Runtime::Registry] the booted registry, queried for the single
      #   loaded chapter providing `"authorization"`
      # @param actor_id [String] the actor to look up, compared as a String
      # @return [String, nil] the role name of the actor's first live (not ended) grant, or
      #   nil if it has none
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` do
      #   not number exactly one
      def live_role_for(registry, actor_id:)
        rows = Runtime::Dispatcher.new(registry).query(
          provided_verb(registry, :assignments),
          actor_id: { value: actor_id.to_s }
        )

        live = rows.find { |row| row[:ends_at].nil? }
        live && live[:role_name][:value]
      end

      # Resolves the one query verb (`assignments` or `transitions`) the loaded
      # authorization-providing chapter declares, refusing an ambiguous wiring.
      #
      # The verb, read from the provider's own declaration — `provides
      # "authorization", assignments: ..., transitions: ...` on whichever
      # loaded chapter declares it (Governance's, in every boot today).
      # Exactly one provider, the same "the runtime will not choose for
      # you" rule `Ports::Authorization.adapter` applies to adapters.
      #
      # @param registry [Runtime::Registry] the booted registry to search for chapters
      #   providing `"authorization"`
      # @param key [Symbol] `:assignments` or `:transitions` — which declared verb to resolve
      # @return [String] the query name the provider declared for `key`
      # @raise [Runtime::WiringError] if the loaded chapters providing `"authorization"` do
      #   not number exactly one
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
