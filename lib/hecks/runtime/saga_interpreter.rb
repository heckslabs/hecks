require "json"
require_relative "saga_interpreter/correlation"
require_relative "../bluebook/process_manager"
require_relative "errors"
require_relative "reaction_invocation"
require_relative "value"
require_relative "saga_pending_dispatch"

module Hecks
  module Runtime
    # Runs one domain's declared process managers against a just-emitted
    # event, checkpointing each transition durably before its dispatches run.
    class SagaInterpreter
      include Correlation

      # The trigger lives on the declaration it triggers — see ProcessManager::REFUSED.
      REFUSED = Bluebook::ProcessManager::REFUSED

      # A crash gets this many retries before it's treated as something to
      # compensate for, instead of unwinding on the first failure.
      MAX_DEFECT_RETRIES = 3

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry whose declared
      #   process managers and saga persistence this interpreter runs against
      # @param door [Runtime::Dispatcher] the dispatcher a saga leg's own dispatch
      #   re-enters through
      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      # Runs `domain`'s declared process managers against `event`: begins,
      # advances or ends each matching saga instance.
      #
      # @param event [Runtime::Event] the just-emitted event to react to
      # @param domain [String, Symbol] the domain whose declared process managers
      #   are checked
      # @param only [Bluebook::ProcessManager, nil] one process manager to run
      #   exactly, instead of every manager `domain` declares
      # @return [void]
      def advance(event, domain, only: nil)
        bluebook = @registry.bluebook(domain)
        return unless bluebook

        (only ? [only] : bluebook.process_managers).each do |process_manager|
          begin_saga(process_manager, event, domain)
          advance_saga(process_manager, event, domain)
          end_saga(process_manager, event, domain)
        end
      end

      private

      # Holds `saga_mutex` across both the in-memory mutation and the
      # persistence write, never just the mutation — otherwise two threads
      # racing the same (process_manager, correlation) key could interleave
      # their writes out of order. `pending:` is injected into the written
      # copy only, never into `instance[:memory]` itself.
      def checkpoint(process_manager, correlation, instance, domain, pending: nil)
        memory = deep_copy(instance[:memory])
        memory[SAGA_PENDING_DISPATCH_KEY] = pending if pending
        @registry.saga_persistence(domain).save_saga(
          process_manager: process_manager.name, correlation: correlation,
          state: instance[:state], memory: memory,
          completed_compensations: deep_copy_array(instance[:completed_compensations])
        )
      end

      # Wrapped in a Hash before the round-trip since `JSON.parse` only
      # accepts an object at the top level. `|| []` rehydrates a ledger
      # that has never completed a compensable leg to empty, never nil.
      def deep_copy_array(array) = deep_copy(list: array || [])[:list]

      def deep_copy(hash) = JSON.parse(JSON.generate(hash), symbolize_names: true)

      def begin_saga(process_manager, event, domain)
        return unless event.name == process_manager.starts_on

        correlation = saga_correlation(process_manager, event)
        if correlation.to_s.empty?
          @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                  born: false, reason: "no #{process_manager.correlates_by} in the payload" }
          return
        end

        created = @registry.saga_mutex.synchronize do
          next false if @registry.saga_instances[process_manager.name].key?(correlation)

          # `.dup` — a fresh saga's own memory starts as a copy of the
          # starting event's payload, never the frozen payload itself,
          # since memory is written into over the saga's lifetime.
          instance = { state: process_manager.states.first, memory: event.payload.dup, completed_compensations: [] }
          @registry.saga_instances[process_manager.name][correlation] = instance
          checkpoint(process_manager, correlation, instance, domain)
          true
        end
        return unless created

        @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                instance: correlation, born: true, state: process_manager.states.first }
      end

      # The mutex covers only the check-mutate-checkpoint step, never the
      # dispatch cascade that follows — `deliver_saga_dispatch`'s
      # `@door.reenter` can recursively re-enter this interpreter on the
      # same thread, and `Mutex` is not reentrant.
      def advance_saga(process_manager, event, domain)
        return unless process_manager.handles?(event.name)

        correlation = saga_correlation(process_manager, event)
        return if correlation.to_s.empty?

        record    = { process_manager: process_manager.name, on: event.name, instance: correlation }
        instance  = nil
        handler   = nil
        pre_state = nil

        advanced = @registry.saga_mutex.synchronize do
          instance = @registry.saga_instances[process_manager.name][correlation]
          unless instance
            @registry.saga_log << record.merge(advanced: false, reason: "no conversation remembers #{correlation.inspect}")
            next false
          end
          # Leg chosen by (event, current state) — read under the mutex so
          # two legs on the same event pick based on the state that's
          # actually current right now.
          handler = process_manager.handler_for(event.name, instance[:state])
          unless handler
            @registry.saga_log << record.merge(advanced: false,
                                               reason:   leg_mismatch(process_manager, event.name, instance[:state]))
            next false
          end

          pre_state = instance[:state]
          instance[:state] = handler.to_state
          checkpoint(process_manager, correlation, instance, domain,
                     pending: pending_marker(event, handler, pre_state, instance[:state]))
          true
        end
        return unless advanced

        settle_transition(process_manager, event, handler, instance, correlation, domain, record, pre_state)
      end

      def leg_mismatch(process_manager, event_name, state)
        expected = process_manager.handlers_for(event_name).map { |h| h.from_state.inspect }.uniq
        "in #{state.inspect}, not #{expected.join(' or ')}"
      end

      def pending_marker(event, handler, from_state, to_state)
        { on: event.name, from: from_state, to: to_state, dispatches: handler.dispatches.map(&:command_name) }
      end

      # The shared tail of `advance_saga` and `unwind`, both of which guard,
      # mutate and checkpoint under the mutex before calling this.
      def settle_transition(process_manager, event, handler, instance, correlation, domain, record, pre_state,
                            drain_compensations: false)
        # from:/to: read back from `instance` itself, never re-derived from
        # `handler.from_state`/`to_state` — otherwise a log entry checked
        # against that same handler object could never actually disagree
        # with it, no matter what the runtime did.
        @registry.saga_log << record.merge(advanced: true, from: pre_state, to: instance[:state])

        # Derived compensations run newest-first, before any hand-written
        # `on :refused` dispatches below. Drained (popped), not just read —
        # that's what keeps a re-entrant `on :refused` from running twice.
        if drain_compensations
          compensations = instance[:completed_compensations] || []
          deliver_derived_compensation(process_manager, compensations.pop, correlation, domain) until compensations.empty?
          checkpoint(process_manager, correlation, instance, domain)
        end

        handler.dispatches.each do |spec|
          deliver_saga_dispatch(process_manager, spec, event, instance, correlation, domain)
        end

        # Guarded by `.equal?` (not `==`): `deliver_saga_dispatch`'s own
        # `reenter` can trigger this correlation's `ends_on` as a nested
        # reaction, deleting this row before this line runs. Clearing
        # unconditionally would resurrect an already-ended saga, or stamp
        # a reborn instance with a stale one's state.
        @registry.saga_mutex.synchronize do
          next unless @registry.saga_instances[process_manager.name][correlation].equal?(instance)

          checkpoint(process_manager, correlation, instance, domain, pending: nil)
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- the checkpoint/
      # dispatch/compensation ledger protocol reads best as one sequence.
      def deliver_saga_dispatch(process_manager, spec, event, instance, correlation, domain)
        args   = dispatch_args(process_manager, spec, event, instance, correlation)
        record = { process_manager: process_manager.name, instance: correlation, dispatch: spec.command_name }

        # Raw inputs captured alongside the resolved result — never
        # re-derived later from saga_instances, which only ever holds the
        # final memory, not what it was at the moment this dispatch fired.
        unless spec.with_spec.to_a.empty?
          @registry.saga_dispatch_log << { process_manager: process_manager.name, instance: correlation,
                                           dispatch: spec.command_name,
                                            on: event.name, correlation_head: process_manager.correlation_head,
                                            event_payload: event.payload, memory: Value.materialize(instance[:memory]),
                                            with_spec: spec.with_spec, args: args }
        end

        if @door.reaction_depth_reached?
          # Not a domain decision, but unambiguous — the leg didn't run, so
          # it unwinds like a refusal rather than stranding the instance.
          @registry.saga_log << record.merge(delivered: false,
                                             reason:    "reaction depth #{@door.max_reaction_depth} reached")
          unwind(process_manager, event, instance, correlation, domain)
          return
        end

        attempt = 0
        compensation_recorded = false
        begin
          # Recorded before dispatching, not after `@door.reenter` returns —
          # reenter can recursively re-enter this interpreter and refuse
          # before ever returning here, and recording only on success would
          # be too late for that nested refusal to see this leg's own
          # compensation. Popped back off in the rescues below if this
          # leg's own attempt is the one that failed.
          if spec.compensates && !compensation_recorded
            resolved = dispatch_args(process_manager, spec.compensates, event, instance, correlation)
            instance[:completed_compensations] << { command_name: spec.compensates.command_name, args: resolved }
            checkpoint(process_manager, correlation, instance, domain)
            compensation_recorded = true
          end

          invocation = ReactionInvocation.build(
            registry:        @registry,
            verb:            qualified(spec.command_name, domain),
            projected:       args,
            explicit:        ReactionInvocation.projection_declared?(spec),
            passthrough:     [process_manager.correlation_head],
            source_receiver: { aggregate: event.aggregate, identity: event.id }
          )
          @door.reenter(qualified(spec.command_name, domain),
                        saga_correlation: { process_manager.correlation_head.to_s => correlation }, **invocation)
          @registry.saga_log << record.merge(delivered: true)
        rescue *DOMAIN_REFUSALS => e
          unrecord_compensation(instance, correlation, domain, process_manager) if compensation_recorded
          # A refusal by the target is a recorded outcome, and the leg
          # that raised it unwinds and runs its own compensation there.
          @registry.saga_log << record.merge(delivered: false, reason: e.message)
          unwind(process_manager, event, instance, correlation, domain)
        rescue StandardError => e
          unrecord_compensation(instance, correlation, domain, process_manager) if compensation_recorded
          compensation_recorded = false
          # Unlike a refusal, a crash isn't a domain decision, so it
          # doesn't unwind on the first failure — MAX_DEFECT_RETRIES lets a
          # transient failure clear on retry. `defect_compensated: true`
          # tags an exhausted retry distinctly, so the log never
          # misrepresents a crash as a decision the domain made.
          attempt += 1
          if attempt <= MAX_DEFECT_RETRIES
            @registry.saga_log << record.merge(delivered: false, reason: e.message,
                                               defect: true, error_class: e.class.name,
                                               attempt: attempt, retrying: true)
            retry
          end

          warn "[hecks] defect in saga #{process_manager.name} — instance #{correlation.inspect} " \
               "dispatching #{spec.command_name} after #{attempt} attempts: #{e.class}: #{e.message}"
          @registry.saga_log << record.merge(delivered: false, reason: e.message, defect: true,
                                             error_class: e.class.name, defect_compensated: true)
          unwind(process_manager, event, instance, correlation, domain)
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      # `.pop`, not search-and-delete — nothing else can have pushed after
      # this leg's own entry without this leg's own `reenter` having
      # already returned first.
      def unrecord_compensation(instance, correlation, domain, process_manager)
        instance[:completed_compensations].pop
        checkpoint(process_manager, correlation, instance, domain)
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
      def unwind(process_manager, event, instance, correlation, domain)
        return unless instance && process_manager.handles?(REFUSED)

        record    = { process_manager: process_manager.name, on: REFUSED, instance: correlation }
        handler   = nil
        pre_state = nil

        # Same non-reentrancy reasoning as `advance_saga`'s own comment —
        # the mutex covers only the check-mutate-checkpoint step.
        advanced = @registry.saga_mutex.synchronize do
          handler = process_manager.handler_for(REFUSED, instance[:state])
          unless handler
            @registry.saga_log << record.merge(advanced: false,
                                               reason:   leg_mismatch(process_manager, REFUSED, instance[:state]))
            next false
          end

          pre_state = instance[:state]
          instance[:state] = handler.to_state
          checkpoint(process_manager, correlation, instance, domain,
                     pending: pending_marker(event, handler, pre_state, instance[:state]))
          true
        end
        return unless advanced

        # `drain_compensations: true` only here — `advance_saga`'s own call
        # never fires derived compensation.
        settle_transition(process_manager, event, handler, instance, correlation, domain, record, pre_state,
                          drain_compensations: true)
      end

      # `entry[:args]` is already resolved, so this skips `dispatch_args`
      # and goes straight to delivery. Never re-enters `unwind` on its own
      # failure — `compensation_failed: true` tags a refused compensation
      # distinctly rather than as an ordinary failed delivery.
      def deliver_derived_compensation(process_manager, entry, correlation, domain)
        record = { process_manager: process_manager.name, instance: correlation, dispatch: entry[:command_name] }

        attempt = 0
        begin
          invocation = ReactionInvocation.build(
            registry:        @registry,
            verb:            qualified(entry[:command_name], domain),
            projected:       entry[:args],
            explicit:        true,
            passthrough:     [process_manager.correlation_head],
            source_receiver: nil
          )
          @door.reenter(qualified(entry[:command_name], domain),
                        saga_correlation: { process_manager.correlation_head.to_s => correlation }, **invocation)
          @registry.saga_log << record.merge(delivered: true, compensation: true)
        rescue *DOMAIN_REFUSALS => e
          @registry.saga_log << record.merge(delivered: false, reason: e.message, compensation: true,
                                             compensation_failed: true)
        rescue StandardError => e
          attempt += 1
          if attempt <= MAX_DEFECT_RETRIES
            @registry.saga_log << record.merge(delivered: false, reason: e.message, compensation: true,
                                               defect: true, error_class: e.class.name,
                                               attempt: attempt, retrying: true)
            retry
          end

          warn "[hecks] defect compensating saga #{process_manager.name} — instance #{correlation.inspect} " \
               "dispatching #{entry[:command_name]} after #{attempt} attempts: #{e.class}: #{e.message}"
          @registry.saga_log << record.merge(delivered: false, reason: e.message, compensation: true,
                                             defect: true, error_class: e.class.name, compensation_failed: true)
        end
      end

      def dispatch_args(process_manager, spec, event, instance, correlation)
        ReactionInvocation.resolve_mapping(
          with_spec: spec.with_spec,
          scopes:    [["current event payload", event.payload], ["opening event memory", instance[:memory]]],
          bindings:  { process_manager.correlation_head => correlation },
          label:     "#{process_manager.name}'s dispatch #{spec.command_name}"
        )
      end

      # Unconditionally the saga's own home domain, never inferred from
      # `command_name`'s shape — unlike a policy's explicit `target_domain`
      # (set by `across`), a saga's `dispatch`/`compensates` has no such
      # field, and every command a saga fires lands inside its own
      # bluebook chapter.
      def qualified(command_name, domain)
        "#{domain}::#{command_name}"
      end

      def end_saga(process_manager, event, domain)
        return unless event.name == process_manager.ends_on

        correlation = saga_correlation(process_manager, event)
        return if correlation.to_s.empty?

        ended = @registry.saga_mutex.synchronize do
          next false unless @registry.saga_instances[process_manager.name].delete(correlation)

          @registry.saga_persistence(domain).delete_saga(process_manager: process_manager.name, correlation: correlation)
          true
        end
        return unless ended

        @registry.saga_log << { process_manager: process_manager.name, on: event.name,
                                instance: correlation, ended: true }
      end
    end
  end
end
