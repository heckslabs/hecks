module Hecks
  module Runtime
    # Who is dispatching, bound for the duration of a block — the ambient
    # counterpart to `Runtime.with_registry`, but `Thread.current`-backed
    # rather than a plain module ivar: registry-binding happens at boot
    # time (single-threaded by construction), this happens at dispatch
    # time, which a future per-request caller (docs/rails-integration.md's
    # still-unbuilt `WebDoor`) needs to bind safely under concurrency.
    #
    # A child `Thread.new` spawned mid-block does not inherit this — plain
    # Ruby thread-local semantics — but nothing in this codebase spawns a
    # worker thread mid-dispatch today, so this is a fact worth naming
    # rather than a gap worth solving.
    module Caller
      # `actor_id` is optional, on top of the role that has always been
      # here — a caller that states only a role (every caller before this)
      # is checked the way it always was, string equality against the
      # command's own `role`. A caller that also names who it is lets
      # `CommandRules::Authorization` check a real Governance
      # `RoleAssignment` instead, once the command's domain has Governance
      # attached — see that module's own header for the full split.
      #
      # `as_of` and `scope` are both optional too, and both self-asserted
      # by the caller rather than derived from the command — deliberately:
      # `as_of` is filled at the door from `Ports::Clock.now`, never
      # inside the interpreter (see `Ports::Clock`'s own header), so
      # there is no other place to source it from. `scope` stays here
      # rather than becoming a command-level DSL construct on purpose —
      # a scope check that lived in the bluebook would put an
      # authorization concern inside the domain declaration itself; this
      # keeps it an application-boundary fact instead, the same shape
      # `role`/`actor_id` already are. The tradeoff: a caller states what
      # scope it is acting in, and `holds_role?` verifies a live grant
      # exists for that scope — it does not independently confirm the
      # scope matches whatever the command's own target data belongs to.
      Current = Struct.new(:role, :actor_id, :as_of, :scope, keyword_init: true)

      module_function

      # The ambient caller bound by the innermost enclosing `as` block on this thread.
      #
      # @return [Runtime::Caller::Current, nil] the bound caller, or nil when no `as`
      #   block is on the stack for this thread
      def current = Thread.current[:hecks_caller]

      # Binds the ambient caller for the duration of the block, restoring whatever
      # caller (if any) was bound before, even if the block raises.
      #
      # `actor_id`, `as_of` and `scope` are each optional, self-asserted facts about
      # the caller rather than derived from the command — see `Current`'s own header
      # above for why each stays here instead of becoming a command-level DSL
      # construct.
      #
      # @param role [String] the role the caller states it holds, checked by string
      #   equality against the command's declared `role`
      # @param actor_id [String, nil] who the caller is; when given, lets
      #   `CommandRules::Authorization` check a real Governance `RoleAssignment`
      #   instead of the bare role-string comparison
      # @param as_of [Integer, nil] Unix epoch seconds the caller asserts as "now",
      #   filled at the door from `Ports::Clock.now`; nil leaves a `RoleAssignment`'s
      #   `starts_at` unchecked
      # @param scope [String, nil] the scope the caller states it is acting in,
      #   checked against the matching `RoleAssignment`'s own `scope`; nil skips
      #   that check
      # @yield the code that should see `role`/`actor_id`/`as_of`/`scope` as the
      #   ambient caller
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

      # Clears the ambient caller for the duration of the block, restoring
      # whatever caller (if any) was bound before, even if the block raises.
      #
      # A reaction is the system acting, not the caller who happened to be
      # on the stack when the triggering command ran — `Dispatcher#reenter`
      # clears the ambient caller around a reaction's own dispatch so a
      # triggering caller's role can neither satisfy nor block a reaction
      # command it has nothing to do with.
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
