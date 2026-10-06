module Hecks
  module Runtime
    class CommandInterpreter
      # The steps that hold a command to the domain's own rules: givens, the lifecycle transition,
      # ensures and invariants. Each runs through the shared rules engine.
      module Enforcement
        private

        def step_enforce_givens(ctx)
          step(:enforce_givens) do
            # Structural check before the declared givens (same ordering as
            # NotFound/AlreadyExists at hydration). Also locates the correction
            # target, if `as:` named one, so `step_enforce_ensures` can reuse it.
            ctx.correction_bindings = @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command,
                                                                       domain: ctx.domain)
            @rules.enforce_givens(ctx.instance, ctx.command, ctx.args, domain: ctx.domain,
                                  declaring: ctx.aggregate, parent: ctx.instance, correction: ctx.correction_bindings)
          end
        end

        def step_admissible_transition(ctx)
          ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.aggregate, ctx.command, ctx.instance) }
        end

        def step_enforce_ensures(ctx)
          step(:enforce_ensures) do
            @rules.enforce_ensures(ctx.instance, ctx.command, ctx.args, old: ctx.old_state,
                                   domain: ctx.domain, parent: ctx.instance, correction: ctx.correction_bindings || {})
          end
        end

        def step_enforce_invariants(ctx)
          step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
        end
      end
    end
  end
end
