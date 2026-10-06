require_relative "../errors"
require_relative "../instance"
require_relative "../entity_element"

module Hecks
  module Runtime
    class CommandInterpreter
      # The synchronous cousin of a policy's own `trigger` (see `CommandBuilder#delegates_to`).
      # Runs between a command's own mutations and its ensures/invariants/save, so a refusal here
      # leaves nothing committed on either side. Reimplements the entity pipeline (givens,
      # transition, mutations, ensures) inline, to keep that exact ordering in one place rather
      # than threading state through method boundaries as parameters.
      module Delegation
        # What a `delegates_to` mutation resolved to: the entity, its command, the command's own
        # arguments, the located element, and a view of it for the givens.
        Target = Struct.new(:entity, :command, :args, :element, :view)

        private

        def step_delegate_to_entity(ctx)
          delegation = ctx.command.mutations.find { |mutation| mutation.op == :delegate }
          return unless delegation

          # Not emitted here — C7.2: a refused command records nothing, and the parent's own
          # ensures/invariants/save steps still run after this one. Parked and emitted by
          # `step_emit`, after the parent commits, alongside every other command's events.
          step(:delegate_to_entity) { ctx.pending_delegation = run_delegation(ctx, delegation) }
        end

        # Runs the target entity command's givens, transition, mutations and ensures against the
        # element, answering the command and arguments `step_emit` will emit.
        def run_delegation(ctx, delegation)
          target      = locate_delegate(ctx, delegation)
          transition  = check_delegate_givens(ctx, target)
          old_element = target.command.ensures.empty? ? nil : target.element.dup
          mutate_delegate(ctx, target, transition)
          enforce_delegate_ensures(ctx, target, old_element)
          [target.command, target.args]
        end

        def enforce_delegate_ensures(ctx, target, old_element)
          settled = Instance.new(aggregate: target.entity, id: target.view.id, state: target.element)
          @rules.enforce_ensures(settled, target.command, target.args, old: old_element, domain: ctx.domain, parent: ctx.instance)
        end

        def locate_delegate(ctx, delegation)
          entity, target_command, command_name = resolve_delegation_target(ctx, delegation)
          target_args = mapped_and_gated_delegation_args(ctx, delegation, entity, target_command)
          element = EntityElement.locate_chain(ctx.aggregate, [entity], ctx.instance, target_args, command_name)
          view = Instance.new(aggregate: entity, id: EntityElement.element_identity(entity, element).to_s, state: element)
          Target.new(entity, target_command, target_args, element, view)
        end

        # @return [Object, nil] the transition the target command is admissible under, if any
        def check_delegate_givens(ctx, target)
          @rules.enforce_givens(target.view, target.command, target.args,
                                domain: ctx.domain, declaring: target.entity, parent: ctx.instance)
          @rules.admissible_transition(target.entity, target.command, target.view)
        end

        def mutate_delegate(ctx, target, transition)
          pre = target.element.dup # C4.2 — the update set reads the element as it was
          target.command.mutations.each do |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, target.entity, target.element, mutation, target.args, pre)
          end
          target.element[target.entity.lifecycle.field] = transition.target if transition
        end

        # The entity and command a `delegates_to` mutation names, resolved once so
        # `step_delegate_to_entity` can read them as plain locals.
        def resolve_delegation_target(ctx, delegation)
          entity_name, _dot, command_name = delegation.target.to_s.rpartition(".")
          entity = delegation_entity(ctx, entity_name, command_name)
          target_command = entity.command(command_name) ||
                           raise(WiringError, "#{ctx.command.hecks_name} delegates_to " \
                                              "#{entity_name}.#{command_name}, which " \
                                              "#{entity_name} declares no such command")
          [entity, target_command, command_name]
        end

        def delegation_entity(ctx, entity_name, command_name)
          ctx.aggregate.entities.find { |e| e.hecks_name == entity_name } ||
            raise(WiringError, "#{ctx.command.hecks_name} delegates_to #{entity_name}." \
                               "#{command_name}, but #{ctx.aggregate.hecks_name} has no " \
                               "entity named #{entity_name.inspect}")
        end

        # Builds the target command's own args, then runs the same argument gate
        # `EntityInterpreter` runs before a direct dispatch of that command — evaluated
        # against the target command's own declared attributes and the already
        # `with:`-mapped args, not the delegating command's. Without this, a `with:`
        # mapping that omits one of the target's required attributes would silently
        # mutate and persist state that was never validated at all.
        # `extra_identity_heads:` exempts the entity's own identity field (e.g. `id`),
        # which locates the element but is never a declared attribute.
        def mapped_and_gated_delegation_args(ctx, delegation, entity, target_command)
          # `with:` remaps, it does not enumerate — starting from a copy of this command's
          # own resolved args and overlaying the explicit mapping means ambient context the
          # caller never named (the aggregate's own identity) still flows through to the
          # target, the same as a direct dispatch of the entity command would get.
          target_args = ctx.args.merge(
            delegation.source.to_h { |target_key, source_key| [target_key.to_sym, ctx.args[source_key]] }
          )
          # The target is dispatched as if called directly, so its needs and defaults are filled
          # too.
          target_args = enrich_arguments(target_command, target_args)

          refuse_unknown_arguments(ctx.domain, ctx.aggregate, target_command, target_args,
                                   extra_identity_heads: entity.identity_heads)
          refuse_absent_arguments(target_command, target_args)
          normalize_args(ctx.aggregate, target_command, target_args)
        end
      end
    end
  end
end
