module Hecks
  module Runtime
    # WHO IS DISPATCHING, bound for the duration of a block — the ambient
    # counterpart to `Runtime.with_registry`, but `Thread.current`-backed
    # rather than a plain module ivar: registry-binding happens at BOOT
    # time (single-threaded by construction), this happens at DISPATCH
    # time, which a future per-request caller (docs/rails-integration.md's
    # still-unbuilt `WebDoor`) needs to bind safely under concurrency.
    #
    # A child `Thread.new` spawned mid-block does not inherit this — plain
    # Ruby thread-local semantics — but nothing in this codebase spawns a
    # worker thread mid-dispatch today, so this is a fact worth naming
    # rather than a gap worth solving.
    module Caller
      # `actor_id` is OPTIONAL, on top of the role that has always been
      # here — a caller that states only a role (every caller before this)
      # is checked the way it always was, string equality against the
      # command's own `role`. A caller that also names WHO it is lets
      # `CommandRules::Authorization` check a real Governance
      # `RoleAssignment` instead, once the command's domain has Governance
      # attached — see that module's own header for the full split.
      Current = Struct.new(:role, :actor_id, keyword_init: true)

      module_function

      def current = Thread.current[:hecks_caller]

      def as(role:, actor_id: nil)
        previous = Thread.current[:hecks_caller]
        Thread.current[:hecks_caller] = Current.new(role: role.to_s, actor_id: actor_id&.to_s)
        yield
      ensure
        Thread.current[:hecks_caller] = previous
      end

      # A REACTION IS THE SYSTEM ACTING, not the caller who happened to be
      # on the stack when the triggering command ran — `Dispatcher#reenter`
      # clears the ambient caller around a reaction's own dispatch so a
      # triggering caller's role can neither satisfy nor block a reaction
      # command it has nothing to do with.
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
