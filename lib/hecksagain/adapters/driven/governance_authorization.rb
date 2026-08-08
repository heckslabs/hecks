module Hecksagain
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

      def holds_role?(registry, actor_id:, role:)
        rows = Runtime::Dispatcher.new(registry).query(
          "Governance::RoleAssignment.AssignmentsForActor",
          actor_id: { value: actor_id.to_s }
        )

        rows.any? { |row| row[:role_name][:value] == role.to_s && row[:ends_at].nil? }
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
