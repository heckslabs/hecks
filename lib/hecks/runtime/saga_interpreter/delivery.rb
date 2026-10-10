require_relative "../errors"
require_relative "../reaction_invocation"
require_relative "../value"

module Hecks
  module Runtime
    class SagaInterpreter
      # Delivers the commands a saga leg dispatches: the retries of a crash and the unwinding of a
      # refusal. Mixed into {SagaInterpreter}, which owns the checkpointing and the transitions.
      module Delivery
        # How many times one dispatch has been tried, and whether its compensation is on the
        # ledger, so a retry records it afresh and a failure pops it back off.
        Ledger = Struct.new(:attempts, :recorded)

        private

        # Delivers one command a saga leg dispatches: resolves its arguments, logs the inputs they
        # were bound from, then runs the checkpoint/dispatch/compensation ledger protocol with the
        # retries a crash gets.
        # rubocop:disable-next Metrics/ParameterLists -- spec/runtime/reaction_invocation_spec.rb calls it by name
        def deliver_saga_dispatch(process_manager, spec, event, instance, correlation, domain)
          leg    = Leg.new(process_manager, event, domain, correlation, nil, instance)
          args   = dispatch_args(process_manager, spec, event, instance, correlation)
          record = { process_manager: process_manager.name, instance: correlation, dispatch: spec.command_name }

          log_dispatch_inputs(leg, spec, args) unless spec.with_spec.to_a.empty?
          return refuse_at_depth_ceiling(leg, record) if @dispatcher.reaction_depth_reached?

          attempt_dispatch(leg, spec, args, record)
        end

        # Raw inputs captured alongside the resolved result — never
        # re-derived later from saga_instances, which only ever holds the
        # final memory, not what it was at the moment this dispatch fired.
        def log_dispatch_inputs(leg, spec, args)
          process_manager = leg.process_manager
          @registry.saga_dispatch_log << { process_manager: process_manager.name, instance: leg.correlation,
                                           dispatch: spec.command_name,
                                           on: leg.event.name, correlation_head: process_manager.correlation_head,
                                           event_payload: leg.event.payload,
                                           memory: Value.materialize(leg.instance[:memory]),
                                           with_spec: spec.with_spec, args: args }
        end

        # Not a domain decision, but unambiguous — the leg didn't run, so
        # it unwinds like a refusal rather than stranding the instance.
        def refuse_at_depth_ceiling(leg, record)
          @registry.saga_log << record.merge(delivered: false,
                                             reason:    "reaction depth #{@dispatcher.max_reaction_depth} reached")
          unwind(leg)
        end

        # Runs the dispatch until it settles: delivered, refused (the leg unwinds), or crashed
        # past `MAX_DEFECT_RETRIES`.
        def attempt_dispatch(leg, spec, args, record)
          ledger = Ledger.new(0, false)
          loop do
            error = dispatch_once(leg, spec, args, record, ledger)
            return unless error

            ledger.attempts += 1
            return abandon_dispatch(leg, spec, record, error, ledger.attempts) if ledger.attempts > MAX_DEFECT_RETRIES

            log_defect_retry(record, error, ledger.attempts)
          end
        end

        # One try. Answers nil once the dispatch has settled (delivered, or refused and unwound),
        # or the crash that stopped it.
        def dispatch_once(leg, spec, args, record, ledger)
          record_compensation(leg, spec, ledger)
          reenter_dispatch(leg, spec, args)
          @registry.saga_log << record.merge(delivered: true)
          nil
        rescue *DOMAIN_REFUSALS => e
          settle_refusal(leg, record, ledger, e)
        rescue StandardError => e
          unrecord_compensation(leg) if ledger.recorded
          ledger.recorded = false
          e
        end

        def reenter_dispatch(leg, spec, args)
          reenter_command(leg, spec.command_name, args,
                          explicit:        ReactionInvocation.projection_declared?(spec),
                          source_receiver: { aggregate: leg.event.aggregate, identity: leg.event.id })
        end

        # A refusal by the target is a recorded outcome, and the leg
        # that raised it unwinds and runs its own compensation there.
        def settle_refusal(leg, record, ledger, error)
          unrecord_compensation(leg) if ledger.recorded
          @registry.saga_log << record.merge(delivered: false, reason: error.message)
          unwind(leg)
          nil
        end

        # Dispatches `command_name` through the dispatcher, stamped with this saga's correlation.
        def reenter_command(leg, command_name, projected, explicit:, source_receiver:)
          head = leg.process_manager.correlation_head
          verb = qualified(command_name, leg.domain)
          invocation = ReactionInvocation.build(registry: @registry, verb: verb, projected: projected,
                                                explicit: explicit, passthrough: [head],
                                                source_receiver: source_receiver)
          @dispatcher.reenter(verb, saga_correlation: { head.to_s => leg.correlation }, **invocation)
        end

        # Unlike a refusal, a crash isn't a domain decision, so it
        # doesn't unwind on the first failure — MAX_DEFECT_RETRIES lets a
        # transient failure clear on retry.
        def log_defect_retry(record, error, attempt)
          @registry.saga_log << record.merge(delivered: false, reason: error.message,
                                             defect: true, error_class: error.class.name,
                                             attempt: attempt, retrying: true)
        end

        # `defect_compensated: true` tags an exhausted retry distinctly, so the log never
        # misrepresents a crash as a decision the domain made.
        def abandon_dispatch(leg, spec, record, error, attempt)
          warn "[hecks] defect in saga #{leg.process_manager.name} — instance #{leg.correlation.inspect} " \
               "dispatching #{spec.command_name} after #{attempt} attempts: #{error.class}: #{error.message}"
          @registry.saga_log << record.merge(delivered: false, reason: error.message, defect: true,
                                             error_class: error.class.name, defect_compensated: true)
          unwind(leg)
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
      end
    end
  end
end
