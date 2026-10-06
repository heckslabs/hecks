module Hecks
  module Runtime
    class SagaInterpreter
      # Moves a saga instance between states: takes the leg an event selects, checkpoints it under
      # the mutex, then settles it by running the leg's dispatches. Mixed into {SagaInterpreter}.
      module Transitions
        private

        def advance_saga(process_manager, event, domain)
          return unless process_manager.handles?(event.name)

          correlation = saga_correlation(process_manager, event)
          return if correlation.to_s.empty?

          record = { process_manager: process_manager.name, on: event.name, instance: correlation }
          leg    = Leg.new(process_manager, event, domain, correlation, record)
          return unless @registry.saga_mutex.synchronize { remembered_leg_taken?(leg) }

          settle_transition(leg)
        end

        # The mutex covers only the check-mutate-checkpoint step, never the
        # dispatch cascade that follows — `deliver_saga_dispatch`'s
        # `@door.reenter` can recursively re-enter this interpreter on the
        # same thread, and `Mutex` is not reentrant.
        def remembered_leg_taken?(leg)
          leg.instance = @registry.saga_instances[leg.process_manager.name][leg.correlation]
          unless leg.instance
            log_leg(leg, advanced: false, reason: "no conversation remembers #{leg.correlation.inspect}")
            return false
          end

          leg_taken?(leg, leg.event.name)
        end

        # Leg chosen by (event, current state) — read under the mutex so
        # two legs on the same event pick based on the state that's
        # actually current right now. Answers whether a leg was taken.
        def leg_taken?(leg, trigger)
          handler = leg.process_manager.handler_for(trigger, leg.instance[:state])
          unless handler
            log_leg(leg, advanced: false, reason: leg_mismatch(leg.process_manager, trigger, leg.instance[:state]))
            return false
          end

          leg.take(handler)
          checkpoint_leg(leg, pending: leg.pending_marker)
          true
        end

        def leg_mismatch(process_manager, event_name, state)
          expected = process_manager.handlers_for(event_name).map { |h| h.from_state.inspect }.uniq
          "in #{state.inspect}, not #{expected.join(" or ")}"
        end

        # The shared tail of `advance_saga` and `unwind`, both of which guard,
        # mutate and checkpoint under the mutex before calling this.
        def settle_transition(leg, drain_compensations: false)
          # from:/to: read back from `instance` itself, never re-derived from
          # `handler.from_state`/`to_state` — otherwise a log entry checked
          # against that same handler object could never actually disagree
          # with it, no matter what the runtime did.
          log_leg(leg, advanced: true, from: leg.pre_state, to: leg.instance[:state])

          drain_derived_compensations(leg) if drain_compensations
          leg.handler.dispatches.each do |spec|
            deliver_saga_dispatch(leg.process_manager, spec, leg.event, leg.instance, leg.correlation, leg.domain)
          end
          clear_pending_marker(leg)
        end

        # Guarded by `.equal?` (not `==`): `deliver_saga_dispatch`'s own
        # `reenter` can trigger this correlation's `ends_on` as a nested
        # reaction, deleting this row before this line runs. Clearing
        # unconditionally would resurrect an already-ended saga, or stamp
        # a reborn instance with a stale one's state.
        def clear_pending_marker(leg)
          @registry.saga_mutex.synchronize do
            next unless @registry.saga_instances[leg.process_manager.name][leg.correlation].equal?(leg.instance)

            checkpoint_leg(leg, pending: nil)
          end
        end

        # A refused leg unwinds by running its own declared `on :refused`
        # handler, where compensation lives — also the destination for a
        # leg that hit the reaction-depth ceiling or exhausted its defect
        # retries.
        #
        # A compensation that is itself refused does not unwind again: the
        # state moves to the compensating leg's to_state before its
        # dispatches run, so a second refusal finds the instance already
        # out of from_state and records that instead.
        def unwind(leg)
          process_manager = leg.process_manager
          return unless leg.instance && process_manager.handles?(REFUSED)

          record  = { process_manager: process_manager.name, on: REFUSED, instance: leg.correlation }
          refused = Leg.new(process_manager, leg.event, leg.domain, leg.correlation, record, leg.instance)

          # Same non-reentrancy reasoning as `remembered_leg_taken?`'s own comment —
          # the mutex covers only the check-mutate-checkpoint step.
          return unless @registry.saga_mutex.synchronize { leg_taken?(refused, REFUSED) }

          # `drain_compensations: true` only here — `advance_saga`'s own call
          # never fires derived compensation.
          settle_transition(refused, drain_compensations: true)
        end
      end
    end
  end
end
