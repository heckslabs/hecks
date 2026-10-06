require_relative "../../bluebook/expression/resolver"
require_relative "../invalid_value_generator"
require_relative "../value_generator"
require_relative "../../runtime/errors"
require_relative "../../runtime/value"
require_relative "../../naming"
require_relative "argument_drawing"
require_relative "identity_shaping"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Turn a picked entry into a corpus step: generate its arguments,
      # occasionally malform exactly one of them, shape its identity, and
      # dispatch it for real.
      module StepBuilder
        include ArgumentDrawing
        include IdentityShaping

        private

        def build_query_step(runtime, entry)
          args = args_for(entry[:query].attributes, entry[:aggregate])
          bind_to_written_row!(args, entry)
          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        # A report ask. Its only argument is `reference_name`, on a rooted model.
        # The id stays a bare scalar: `ReadModelInterpreter#refuse_object_reference`
        # rejects a wrapped identity.
        def build_read_model_step(runtime, entry)
          model = entry[:model]
          args  = model.reference_target.nil? ? {} : { model.reference_name.to_s => pick_known(model.reference_target) }

          safe_call { runtime.query(entry[:verb], **symbolize(args)) }
          { "query" => entry[:verb], "args" => args }
        end

        # The adversarial mutation happens here, after the args and identity are
        # built and before the one inline dispatch, so the dispatch, the corpus
        # step and both replay engines all see the same mutated payload.
        #
        # The caller draw and then the dry-run coin follow the mutation. The order
        # is part of the seed contract; both draw nothing when off.
        def build_command_step(runtime, catalog, entry)
          args = command_args(entry, catalog)
          mutations = adversarial_mutations!(args, entry, catalog)
          caller, caller_note = caller_draw!(entry, catalog)
          mutations << caller_note if caller_note
          @state_before = state_before(runtime, entry, args)

          step = dispatch_step(runtime, catalog, entry, args, caller)
          step.merge!(caller) if caller
          step["adversarial"] = mutations unless mutations.empty?
          step
        end

        # The arguments of a command step before any adversarial mutation: drawn, then given an
        # identity, then steered toward a grantable role.
        def command_args(entry, catalog)
          args = args_for(entry[:command].attributes, entry[:aggregate], needed: entry[:command].needs.map(&:to_s))
          add_identity!(args, entry)
          steer_grant!(args, entry, catalog)
          args
        end

        # Dispatches the step for real, or as a dry run when the coin says so.
        def dispatch_step(runtime, catalog, entry, args, caller)
          if dry_run_draw?
            safe_call { as_caller(caller) { runtime.dry_run?(entry[:verb], **symbolize(args)) } }
            return { "dry_run" => entry[:verb], "args" => args }
          end

          outcome = safe_call { as_caller(caller) { runtime.dispatch_flat(entry[:verb], symbolize(args)) } }
          record_dispatch(runtime, catalog, entry, args, outcome) if outcome
          { "verb" => entry[:verb], "args" => args }
        end

        def record_dispatch(runtime, catalog, entry, args, outcome)
          record_outcome(catalog, entry, args)
          harvest_written_rows(runtime, catalog)
          @event_count += outcome.events.length
        end

        # Draws nothing when the fraction is zero, like `adversarial?`.
        def dry_run_draw? = @dry_run.positive? && @random.rand < @dry_run

        # Runs the block under `Hecks.as_caller`, the binding `Fuzzing::Replay` makes
        # from the step's keys, or yields bare when there is no caller.
        def as_caller(caller, &)
          return yield unless caller

          Hecks.as_caller(role: caller["role"], actor_id: caller["actor_id"], &)
        end

        def symbolize(args) = args.transform_keys(&:to_sym)

        # A declined step is not a generator failure: nothing is recorded, the
        # sequence carries on, and the step still enters the corpus as a refusal.
        #
        # EvaluationError counts as a refusal (an unreadable payload); any other
        # error propagates and fails spec/fuzzing.
        def safe_call
          result = yield
          @last_outcome = "ok"
          result
        rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError => e
          @last_outcome = e.class.name.split("::").last
          nil
        end

        # The addressed aggregate's lifecycle value before this dispatch, or
        # `exists`/`absent`; `?` when a mutation mangled the identity. Draws nothing from the RNG.
        def state_before(runtime, entry, args)
          record = addressed_record(runtime, entry, args)
          return "absent" unless record

          lifecycle = entry[:aggregate].lifecycle
          return "exists" unless lifecycle

          key = record.state.key?(lifecycle.field) ? lifecycle.field : lifecycle.field.to_s
          record.state[key].to_s
        rescue StandardError
          "?"
        end

        # The stored record the step's identity args address, or nil.
        def addressed_record(runtime, entry, args)
          aggregate = entry[:aggregate]
          symbolic  = symbolize(args)
          id = Runtime::Identity.of(aggregate, symbolic) || Runtime::Identity.from(aggregate, symbolic, :id)
          id && runtime.registry.repository(entry[:verb].split("::").first, aggregate).find(id)
        end
      end
    end
  end
end
