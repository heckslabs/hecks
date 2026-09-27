module Hecks
  module Runtime
    # Who is dispatching, bound for the duration of a block.
    # `Thread.current`-backed, so per-request callers bind safely under concurrency;
    # a child thread spawned mid-block does not inherit it.
    module Caller
      # The bound caller: a role, plus optional `actor_id`, `as_of` and `scope`.
      #
      # All but `role` are self-asserted by the caller, not derived from the command;
      # `scope` is deliberately not a DSL construct, and `holds_role?` checks only that a grant
      # exists for it, not that it matches the command's target data.
      Current = Struct.new(:role, :actor_id, :as_of, :scope, keyword_init: true)

      module_function

      # The ambient caller bound by the innermost enclosing `as` block on this thread.
      #
      # @return [Runtime::Caller::Current, nil] the bound caller, or nil when no `as`
      #   block is on the stack for this thread
      def current = Thread.current[:hecks_caller]

      # Binds the ambient caller for the duration of the block, restoring the previous
      # one even if the block raises.
      #
      # @param role [String] the role the caller holds, checked against the command's `role`
      # @param actor_id [String, nil] who the caller is; when given, `CommandRules::Authorization`
      #   checks a real Governance `RoleAssignment`
      # @param as_of [Integer, nil] Unix epoch seconds taken as "now"; nil leaves a
      #   `RoleAssignment`'s `starts_at` unchecked
      # @param scope [String, nil] the scope acted in, checked against the `RoleAssignment`'s
      #   `scope`; nil skips that check
      # @yield the code that sees these values as the ambient caller
      # @return [Object] the block's result
      def as(role:, actor_id: nil, as_of: nil, scope: nil)
        previous = Thread.current[:hecks_caller]
        Thread.current[:hecks_caller] = Current.new(
          role: role.to_s, actor_id: actor_id&.to_s, as_of: as_of, scope: scope&.to_s
        )
        yield
      ensure
        Thread.current[:hecks_caller] = previous
      end

      # Clears the ambient caller for the duration of the block, restoring the previous one.
      # A reaction is the system acting, so `Dispatcher#reenter` clears the caller around it.
      #
      # @yield the code that should see no ambient caller bound
      # @return [Object] the block's result
      def without
        previous = Thread.current[:hecks_caller]
        Thread.current[:hecks_caller] = nil
        yield
      ensure
        Thread.current[:hecks_caller] = previous
      end
    end
  end
end
