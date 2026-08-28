require "time"

module Hecks
  module Adapters
    # THE `authorization` PORT, FULFILLED BY GOVERNANCE — same registry,
    # same boot, so "ask Governance" is a dispatch against records
    # already sitting in the store this adapter is handed, not a bridge
    # to a second runtime. `Runtime::Dispatcher.new(registry)` is cheap
    # to build fresh per call (`Registry#capability_graph`'s own
    # neighbor, `#repository`, does the same kind of on-demand build) —
    # nothing here holds one across calls, so there is no boot-order
    # dependency on WHEN Governance's bluebook loads relative to this
    # adapter, only that it has by the time `holds_role?` is called.
    #
    # AN ACTIVE ASSIGNMENT, not merely a historical one : `RoleAssignment`
    # answers with every assignment an actor has ever held
    # (`AssignmentsForActor`'s own description — "currently or
    # historically") and leaves `ends_at` for the caller to read, the
    # same deferral `Governance::RoleTransition.Allowed` makes for the
    # same reason. This is that caller.
    module GovernanceAuthorization
      module_function

      # `as_of` and `scope` are BOTH optional, same opt-in shape
      # `refuse_role_mismatch` already gives `actor_id` itself — an
      # unbound `as_of` skips the `starts_at` check and an unbound
      # `scope` skips the `scope` check, exactly the behavior before
      # either existed. Neither is fetched here: `as_of` arrives already
      # resolved from `Ports::Clock.now`, called by the caller at the
      # door, never by this adapter — see `Ports::Clock`'s own header
      # for why the dispatch path must not consult the clock itself.
      def holds_role?(registry, actor_id:, role:, as_of: nil, scope: nil)
        rows = Runtime::Dispatcher.new(registry).query(
          "Governance::RoleAssignment.AssignmentsForActor",
          actor_id: { value: actor_id.to_s }
        )

        rows.any? do |row|
          row[:role_name][:value] == role.to_s &&
            row[:ends_at].nil? &&
            in_scope?(row, scope) &&
            started?(row, as_of)
        end
      end

      # `scope` UNCHECKED WHEN NOT STATED, same as every other opt-in
      # field here — a caller that never says which scope it is acting
      # in gets the pre-scope behavior: any live assignment for the role
      # authorizes, everywhere. A caller that does state one only
      # authorizes against an assignment granted for THAT scope.
      def in_scope?(row, scope)
        scope.nil? || row[:scope][:value] == scope.to_s
      end

      # `starts_at` IS A FREE-TEXT STRING in the bluebook (`Timestamp`'s
      # only invariant is "present", not any particular format) — parsed
      # here with `Time.parse` rather than compared lexically, since
      # nothing guarantees every caller writes it zero-padded ISO 8601.
      # FAILS CLOSED : a `starts_at` that does not parse is treated as
      # not-yet-started rather than silently ignored, the same direction
      # every other check in this method already fails.
      def started?(row, as_of)
        return true if as_of.nil?

        Time.parse(row[:starts_at][:value].to_s).to_i <= as_of
      rescue ArgumentError, TypeError
        false
      end

      # THE OTHER HALF — may role X act as role Y. `RoleTransition.Allowed`
      # is identified by the exact pair, so at most one row ever comes
      # back ; still read as `.any?` rather than trusting that structurally,
      # the same defensiveness `holds_role?` already has to have anyway
      # since `AssignmentsForActor` can return several.
      def authorized_as?(registry, from_role:, to_role:)
        rows = Runtime::Dispatcher.new(registry).query(
          "Governance::RoleTransition.Allowed",
          from_role: { value: from_role.to_s }, to_role: { value: to_role.to_s }
        )

        rows.any? { |row| row[:ends_at].nil? }
      end

      # THE ROLE ITSELF, not just a yes/no about one — the same
      # `AssignmentsForActor` query `holds_role?` runs, just returning
      # the live (non-revoked) row's `role_name` instead of comparing it
      # against a caller-supplied guess. `nil` for no live assignment at
      # all — the caller's own fallback (an aggregate's own role field,
      # a default) is domain-specific and does not belong here.
      def live_role_for(registry, actor_id:)
        rows = Runtime::Dispatcher.new(registry).query(
          "Governance::RoleAssignment.AssignmentsForActor",
          actor_id: { value: actor_id.to_s }
        )

        live = rows.find { |row| row[:ends_at].nil? }
        live && live[:role_name][:value]
      end
    end
  end
end
