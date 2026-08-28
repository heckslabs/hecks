require "json"
require_relative "saga_interpreter/correlation"
require_relative "../bluebook/process_manager"
require_relative "errors"
require_relative "reaction_invocation"
require_relative "value"
require_relative "saga_pending_dispatch"

module Hecks
  module Runtime
    class SagaInterpreter
      include Correlation

      # The trigger lives on the declaration it triggers, not on the runtime that
      # notices it — see ProcessManager::REFUSED.
      REFUSED = Bluebook::ProcessManager::REFUSED

      # A crash gets this many extra attempts before the procedure gives up
      # and treats it as something to compensate for — see
      # `deliver_saga_dispatch`'s own comment for why a crash isn't unwound
      # on the first failure the way a domain refusal is.
      MAX_DEFECT_RETRIES = 3

      attr_reader :registry

      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      def advance(event, domain)
        bluebook = @registry.bluebook(domain)
        return unless bluebook

        bluebook.process_managers.each do |pm|
          begin_saga(pm, event, domain)
          advance_saga(pm, event, domain)
          end_saga(pm, event, domain)
        end
      end

      private

      # THE CHECKPOINT WRITE, shared by every mutation site below —
      # holds `saga_mutex` across BOTH the in-memory Hash mutation and
      # the persistence write (§7), not just the Hash mutation alone:
      # two threads racing the SAME (process_manager, correlation) key
      # could otherwise interleave their writes out of order, silently
      # reordering a saga's own transition history — worse for the
      # adapters with no locking of their own (Heki) than for Postgres.
      # `deep_copy` guards against the exact shape of bug PR #175 itself
      # already found once (over-freezing a live, still-mutated Hash) —
      # never hand a persistence adapter the SAME object `advance_saga`/
      # `unwind` go on to mutate in place; round-tripping through JSON
      # is also what guarantees the value is safe for every adapter that
      # itself calls `JSON.generate` on it.
      # `pending:` — see saga_pending_dispatch.rb. Injected into the
      # WRITTEN copy of memory only, never into `instance[:memory]`
      # itself: every other reader of a live instance's memory
      # (`dispatch_args`'s "opening event memory" scope, the fuzzer's
      # own round-trip/shape checks, `saga_spec.rb`'s exact-equality
      # assertion against a fresh instance's seeded memory) sees exactly
      # what it always did. The marker exists ONLY in the persisted
      # blob, and only for as long as a dispatch cascade is genuinely
      # in flight for this instance.
      def checkpoint(pm, correlation, instance, domain, pending: nil)
        memory = deep_copy(instance[:memory])
        memory[SAGA_PENDING_DISPATCH_KEY] = pending if pending
        @registry.saga_persistence(domain).save_saga(
          process_manager: pm.name, correlation: correlation,
          state: instance[:state], memory: memory
        )
      end

      def deep_copy(hash) = JSON.parse(JSON.generate(hash), symbolize_names: true)

      def begin_saga(pm, event, domain)
        return unless event.name == pm.starts_on

        correlation = saga_correlation(pm, event)
        if correlation.to_s.empty?
          @registry.saga_log << { process_manager: pm.name, on: event.name,
                                  born: false, reason: "no #{pm.correlates_by} in the payload" }
          return
        end

        created = @registry.saga_mutex.synchronize do
          next false if @registry.saga_instances[pm.name].key?(correlation)

          # `.dup`, NOT THE SAME OBJECT — a fresh saga's own memory starts
          # as a COPY of the starting event's own payload, never the
          # payload itself. A saga's own memory is meant to be written
          # into over its lifetime (remember-style, growing beyond what
          # the starting event carried) ; the payload it was seeded from
          # is a fact about something that ALREADY happened, logged and
          # emitted before the saga ever saw it. Sharing the one Hash
          # object between them means a write into the saga's own memory
          # is silently ALSO a write into an already-emitted event's own
          # payload — retroactively adding a field nothing announced.
          # `event.payload` is deep-frozen by `Event#emit!` by the time
          # this runs, so a naive in-place write here would raise
          # FrozenError rather than corrupt silently — but the `.dup`
          # still matters: it is what makes the saga's own memory a
          # normal, writable Hash of its own, rather than one write away
          # from crashing every future in-place `remember`.
          instance = { state: pm.states.first, memory: event.payload.dup }
          @registry.saga_instances[pm.name][correlation] = instance
          checkpoint(pm, correlation, instance, domain)
          true
        end
        return unless created

        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, born: true, state: pm.states.first }
      end

      # THE MUTEX COVERS ONLY THE STATE-CHECK-AND-MUTATE-AND-CHECKPOINT
      # STEP, never the dispatch cascade that follows — `deliver_saga_
      # dispatch` calls `@door.reenter`, which can recursively re-enter
      # THIS SAME interpreter (a saga's own leg triggering another saga,
      # or itself again) on the SAME thread, and `Mutex` is not
      # reentrant: holding it across that call would deadlock the
      # thread against itself the moment any real chain did that.
      def advance_saga(pm, event, domain)
        handler = pm.handler_for(event.name)
        return unless handler

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?

        record    = { process_manager: pm.name, on: event.name, instance: correlation }
        instance  = nil
        pre_state = nil

        advanced = @registry.saga_mutex.synchronize do
          instance = @registry.saga_instances[pm.name][correlation]
          unless instance
            @registry.saga_log << record.merge(advanced: false, reason: "no conversation remembers #{correlation.inspect}")
            next false
          end
          unless instance[:state] == handler.from_state
            @registry.saga_log << record.merge(advanced: false,
                                               reason:   "in #{instance[:state].inspect}, not #{handler.from_state.inspect}")
            next false
          end

          pre_state = instance[:state]
          instance[:state] = handler.to_state
          checkpoint(pm, correlation, instance, domain,
                     pending: pending_marker(event, handler, pre_state, instance[:state]))
          true
        end
        return unless advanced

        settle_transition(pm, event, handler, instance, correlation, domain, record, pre_state)
      end

      def pending_marker(event, handler, from_state, to_state)
        { on: event.name, from: from_state, to: to_state, dispatches: handler.dispatches.map(&:command_name) }
      end

      # THE SHARED TAIL of `advance_saga` and `unwind` — both are "guard,
      # mutate, checkpoint-with-pending" under the mutex (kept separate
      # per caller: `advance_saga`'s own guard also has to handle "no
      # instance at all", `unwind`'s doesn't), then this: log the real
      # observed transition, run the leg's dispatches, and clear the
      # pending marker once that cascade — however it ended — is done.
      def settle_transition(pm, event, handler, instance, correlation, domain, record, pre_state)
        # `from:`/`to:` are the INSTANCE'S OWN real pre/post state — read
        # back from `instance` itself, never re-derived from `handler.
        # from_state`/`handler.to_state` a second time. `Properties.saga_
        # advances_follow_declared_handlers` (fuzzing/properties.rb) builds
        # its OWN "declared edges" list from this SAME handler object (via
        # `pm.handlers`), so a log entry that just echoed `handler.
        # from_state`/`handler.to_state` back could never disagree with
        # that list no matter what the runtime actually did — the entry
        # and the thing it's checked against would be the identical fact,
        # read twice. Logging the instance's own observed state instead
        # means a future defect that moves an instance somewhere its own
        # declared handler didn't say (a stale handler reference, the
        # wrong handler picked, a second racing mutation) shows up as a
        # real mismatch instead of vanishing into a tautology.
        @registry.saga_log << record.merge(advanced: true, from: pre_state, to: instance[:state])

        handler.dispatches.each do |spec|
          deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        end

        # THE CLEAR — guarded by the SAME identity check `end_saga`'s own
        # `.delete` return value implies: `deliver_saga_dispatch`'s
        # `@door.reenter` can synchronously trigger this SAME correlation's
        # `ends_on` event as a nested reaction (a leg's own dispatch is
        # what makes the saga's terminal event fire), which deletes this
        # row from the store before this line ever runs. Writing the
        # clear unconditionally would RESURRECT a legitimately-ended saga
        # — this diff's own first attempt did exactly that, caught by
        # `saga_durability_spec.rb`'s "deletes the checkpoint once a saga
        # genuinely ends" — so this only re-checkpoints when `instance`
        # is still THE SAME object `@saga_instances` holds for this
        # correlation (`.equal?`, not `==`: a fresh saga reborn under the
        # same correlation between then and now is a DIFFERENT instance,
        # and writing this stale one's state onto that one's row would be
        # its own corruption). Under the mutex — dispatching is over by
        # now, so this is not the reentrancy hazard `advance_saga`'s own
        # comment warns about.
        @registry.saga_mutex.synchronize do
          next unless @registry.saga_instances[pm.name][correlation].equal?(instance)

          checkpoint(pm, correlation, instance, domain, pending: nil)
        end
      end

      def deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        args   = dispatch_args(pm, spec, event, instance, correlation)
        record = { process_manager: pm.name, instance: correlation, dispatch: spec.command_name }

        # THE RAW INPUTS `args` WAS RESOLVED FROM, captured alongside the
        # result — never re-derived from history[:saga_instances] later
        # (that only ever holds the FINAL memory, after every step has
        # run; this dispatch's own memory, at the moment it actually
        # fired, is a different fact for a saga whose memory keeps
        # changing). `spec.with_spec.empty?` skipped: nothing declared
        # to check, a tautological pass, the same reason a command with
        # no givens/from is skipped by lifecycle_guard_and_given_
        # violations_are_refused.
        unless spec.with_spec.to_a.empty?
          @registry.saga_dispatch_log << { process_manager: pm.name, instance: correlation, dispatch: spec.command_name,
                                            on: event.name, correlation_head: pm.correlation_head,
                                            event_payload: event.payload, memory: Value.materialize(instance[:memory]),
                                            with_spec: spec.with_spec, args: args }
        end

        if @door.reaction_depth_reached?
          # THE CEILING IS NOT A DOMAIN DECISION EITHER — same reasoning as a
          # crash, below — but unlike a crash there is nothing ambiguous
          # about it: the leg unambiguously did not run, so it unwinds
          # exactly like a refusal instead of stranding the instance for a
          # human to notice. `unwind`'s own state guard (it moves to its
          # `to_state` before its dispatches run) is what keeps this from
          # looping if the ceiling is still in effect when the compensating
          # leg tries to dispatch — that leg's own attempt hits this same
          # branch, calls `unwind` again, and finds the instance already
          # past `from_state`.
          @registry.saga_log << record.merge(delivered: false,
                                             reason:    "reaction depth #{@door.max_reaction_depth} reached")
          unwind(pm, event, instance, correlation, domain)
          return
        end

        attempt = 0
        begin
          invocation = ReactionInvocation.build(
            registry:        @registry,
            verb:            qualified(spec.command_name, domain),
            projected:       args,
            explicit:        ReactionInvocation.projection_declared?(spec),
            passthrough:     [pm.correlation_head],
            source_receiver: { aggregate: event.aggregate, identity: event.id }
          )
          @door.reenter(qualified(spec.command_name, domain),
                        saga_correlation: { pm.correlation_head.to_s => correlation }, **invocation)
          @registry.saga_log << record.merge(delivered: true)
        rescue *DOMAIN_REFUSALS => error
          # Same rule as the policy interpreter : a refusal by the target is
          # a recorded outcome, and the leg that raised it UNWINDS — see
          # `unwind`'s own comment for why the procedure runs its
          # compensation here rather than leaving the money (or whatever
          # else a leg moved) sitting out.
          @registry.saga_log << record.merge(delivered: false, reason: error.message)
          unwind(pm, event, instance, correlation, domain)
        rescue StandardError => error
          # A DEFECT, not a refusal — see PolicyInterpreter#deliver's own
          # comment for the full reasoning: the same DOMAIN_REFUSALS split,
          # and the same "the triggering command already succeeded and
          # persisted by the time this runs" fact that makes catching it
          # here safe rather than reckless.
          #
          # UNLIKE a refusal, a crash is not a decision the domain made, so
          # it does not unwind on the first failure — MAX_DEFECT_RETRIES
          # gives a transient failure (a DB timeout, a race, a cold start)
          # a chance to clear on its own, retrying the identical dispatch,
          # before this is treated as something to compensate for. Every
          # attempt is recorded distinguishably (`defect: true`, the
          # error's own class); only once retries are exhausted is it
          # warned to STDERR and unwound — tagged `defect_compensated:
          # true` rather than folded into an ordinary refusal's shape, so
          # the log never misrepresents a crash as a decision the domain
          # made. Compensating a genuinely stuck leg beats leaving it for a
          # human to find; misrepresenting *why* it compensated is what the
          # tag is for.
          attempt += 1
          if attempt <= MAX_DEFECT_RETRIES
            @registry.saga_log << record.merge(delivered: false, reason: error.message,
                                               defect: true, error_class: error.class.name,
                                               attempt: attempt, retrying: true)
            retry
          end

          warn "[hecks] defect in saga #{pm.name} — instance #{correlation.inspect} " \
               "dispatching #{spec.command_name} after #{attempt} attempts: #{error.class}: #{error.message}"
          @registry.saga_log << record.merge(delivered: false, reason: error.message, defect: true,
                                             error_class: error.class.name, defect_compensated: true)
          unwind(pm, event, instance, correlation, domain)
        end
      end

      # A refused leg UNWINDS — the procedure runs the leg declared `on :refused`,
      # which is where the compensation lives. So does a leg that hit the
      # reaction-depth ceiling, and so does a leg that crashed and stayed
      # crashing through MAX_DEFECT_RETRIES — see `deliver_saga_dispatch`'s own
      # comments for why each of those is safe to route here.
      #
      # Until this existed a refusal was RECORDED and nothing else happened. The
      # wire's thousand was taken from the source, refused by the destination, and
      # sat nowhere until a human dispatched the reversal by hand ; banking's
      # settlement left a debit standing with no credit and no reversal at all.
      # Both bluebooks had written the compensating leg. Nothing armed it.
      #
      # A compensation that is itself refused does NOT unwind again, and needs no
      # flag to stop it: the state moves to the compensating leg's to_state BEFORE
      # its dispatches run, so a second refusal finds the instance no longer in
      # from_state and records that instead. The check is the guard.
      def unwind(pm, event, instance, correlation, domain)
        handler = pm.handler_for(REFUSED)
        return unless handler && instance

        record    = { process_manager: pm.name, on: REFUSED, instance: correlation }
        pre_state = nil

        # Same non-reentrancy reasoning as `advance_saga`'s own comment —
        # the mutex covers only the check-and-mutate-and-checkpoint step.
        advanced = @registry.saga_mutex.synchronize do
          unless instance[:state] == handler.from_state
            @registry.saga_log << record.merge(advanced: false,
                                               reason:   "in #{instance[:state].inspect}, not #{handler.from_state.inspect}")
            next false
          end

          pre_state = instance[:state]
          instance[:state] = handler.to_state
          checkpoint(pm, correlation, instance, domain,
                     pending: pending_marker(event, handler, pre_state, instance[:state]))
          true
        end
        return unless advanced

        # See `settle_transition`'s own comment on `pre_state`/
        # `instance[:state]` — the real observed transition, not a
        # second read of the SAME handler object `Properties.saga_
        # advances_follow_declared_handlers` checks this log against.
        settle_transition(pm, event, handler, instance, correlation, domain, record, pre_state)
      end

      def dispatch_args(pm, spec, event, instance, correlation)
        ReactionInvocation.resolve_mapping(
          with_spec: spec.with_spec,
          scopes:    [["current event payload", event.payload], ["opening event memory", instance[:memory]]],
          bindings:  { pm.correlation_head => correlation },
          label:     "#{pm.name}'s dispatch #{spec.command_name}"
        )
      end

      def qualified(command_name, domain)
        command_name.include?("::") ? command_name : "#{domain}::#{command_name}"
      end

      def end_saga(pm, event, domain)
        return unless event.name == pm.ends_on

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?

        ended = @registry.saga_mutex.synchronize do
          next false unless @registry.saga_instances[pm.name].delete(correlation)

          @registry.saga_persistence(domain).delete_saga(process_manager: pm.name, correlation: correlation)
          true
        end
        return unless ended

        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, ended: true }
      end
    end
  end
end
