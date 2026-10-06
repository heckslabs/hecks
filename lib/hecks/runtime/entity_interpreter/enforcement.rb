require_relative "../instance"

module Hecks
  module Runtime
    class EntityInterpreter
      # The steps that hold an entity command to the domain's own rules: givens, the lifecycle
      # transition, ensures and the parent aggregate's invariants. Mixed into
      # {EntityInterpreter}.
      module Enforcement
        private

        # Enforces this command's `given`s and correction-target admissibility.
        # Checked against the parent aggregate, never the entity view — every
        # emitted event is stamped with the root aggregate's name and the
        # parent record's id, regardless of dispatch level.
        def step_enforce_givens(ctx)
          step(:enforce_givens) do
            ctx.correction_bindings = @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command,
                                                                       domain: ctx.domain)
            @rules.enforce_givens(ctx.view, ctx.command, ctx.args, domain: ctx.domain, declaring: ctx.entity,
                                  parent: ctx.instance, correction: ctx.correction_bindings)
          end
        end

        def step_admissible_transition(ctx)
          ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.entity, ctx.command, ctx.view) }
        end

        # An ensures reads the settled record, so it needs a view hydrated from
        # `element` as it stands now, mutations included — unlike `view` above,
        # built once and read pre-mutation by enforce_givens.
        def step_enforce_ensures(ctx)
          step(:enforce_ensures) do
            settled = Instance.new(aggregate: ctx.entity, id: ctx.view.id, state: ctx.element)
            # `correction:` reuses the `as:`-bound bindings `step_enforce_givens`
            # already located; `|| {}` covers a command with no `corrects`
            # mutation, where `ctx.correction_bindings` may be unset.
            @rules.enforce_ensures(settled, ctx.command, ctx.args, old: ctx.old_element, domain: ctx.domain,
                                   parent: ctx.instance, correction: ctx.correction_bindings || {})
          end
        end

        # Enforces the parent aggregate's own invariants — there is no separate
        # "entity invariant" concept (ADR 0025 scopes `invariant` to the aggregate).
        def step_enforce_invariants(ctx)
          step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
        end
      end
    end
  end
end
