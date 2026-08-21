require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "refusal_wording"
require_relative "entity_element"

module Hecksagain
  module Runtime
    # The dispatch pipeline for a command on an aggregate head. The payload
    # gate lives in command_interpreter/argument_gate.rb, the mutation walk
    # in command_interpreter/mutation_applier.rb; what stays here is the
    # order of the steps and how a record is addressed.
    class CommandInterpreter
      include Interpreting
      include ArgumentGate
      include MutationApplier

      attr_reader :registry

      # THE DECLARED ORDER, HAND-TYPED — mirrors Vocabulary::AggregateDispatchOrder
      # (language/bluebook/vocabulary.bluebook:188-205), held equal to it by
      # spec/vocabulary_conformance_spec.rb the same way every other vocabulary
      # in that file is (RefusalWording::TEMPLATES, CommandRules::MUTATION_OPS,
      # ...) rather than read live off the meta-domain at every dispatch —
      # Runtime::RefusalWording's own doc comment gives the same reason.
      DISPATCH_ORDER = Hecksagain::Vocabulary.symbols("AggregateDispatchOrder")

      # EVERY CROSS-STEP LOCAL `call` used to thread through its own literal
      # sequence, held in one place now that the sequence is data-driven —
      # `result` and `transition`/`old_state` default to nil until the step
      # that sets them runs, same as they were unset locals before that point.
      Context = Struct.new(:domain, :aggregate, :command, :args, :repository, :instance, :transition, :old_state,
                           :result, :correlation, :delegated_events, :dry_run)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # `dry_run:` — Dispatcher#dry_run's own entry point. Every step up
      # through enforce_ensures/enforce_invariants runs exactly as a real
      # dispatch would (givens checked, mutations applied to `ctx.instance`
      # in memory); `step_save`/`step_emit` are the only two that read this
      # flag, each skipping its own real work — see their own comments.
      def call(domain, aggregate, command, args, correlation = nil, dry_run: false)
        ctx = Context.new(domain, aggregate, command, args)
        ctx.correlation = correlation
        ctx.dry_run = dry_run
        run_dispatch_order(DISPATCH_ORDER, ctx)
        [ctx.instance, ctx.result]
      end

      private

      def step_refuse_unknown_arguments(ctx)
        step(:refuse_unknown_arguments) { refuse_unknown_arguments(ctx.domain, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_absent_arguments(ctx)
        step(:refuse_absent_arguments) { refuse_absent_arguments(ctx.command, ctx.args) }
      end

      def step_normalize_args(ctx)
        ctx.args = step(:normalize_args) { normalize_args(ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_refuse_role_mismatch(ctx)
        step(:refuse_role_mismatch) { @rules.refuse_role_mismatch(ctx.command, ctx.domain) }
      end

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.command, ctx.args) }
      end

      def step_hydrate(ctx)
        ctx.repository = @registry.repository(ctx.domain, ctx.aggregate)
        ctx.instance = step(:hydrate) { hydrate(ctx.repository, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) {
          @rules.enforce_givens(ctx.instance, ctx.command, ctx.args, domain: ctx.domain, declaring: ctx.aggregate)
        }
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.aggregate, ctx.command, ctx.instance) }
      end

      def step_assign_creation_attributes(ctx)
        return unless ctx.command.creates?

        step(:assign_creation_attributes) { assign_creation_attributes(ctx.instance, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_apply_mutations(ctx)
        # The state as the givens saw it — what `old` names inside an
        # ensures. A shallow dup suffices: mutations REPLACE fields (set,
        # arithmetic via Value#with, append builds a new array), never
        # edit a held value in place.
        ctx.old_state = ctx.instance.state.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) {
          ctx.command.mutations.each { |mutation|
            apply(ctx.instance, ctx.aggregate, mutation, ctx.args)
          }
        }
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.instance[ctx.aggregate.lifecycle.field] = ctx.transition.target }
      end

      # THE SYNCHRONOUS COUSIN OF A POLICY'S OWN `trigger` — see
      # `CommandBuilder#delegates_to`'s own comment for the full reasoning.
      # Runs AFTER this command's own mutations/lifecycle (so a delegating
      # command could in principle still guard with its own `given`s first,
      # though the real use in `domain/chess` declares none) and BEFORE
      # `enforce_ensures`/`enforce_invariants`/`save`, so a refusal here
      # raises a real, unrescued exception and NOTHING from either side —
      # this command's own state, the target element's — has been saved
      # yet. `ctx.instance` is the SAME in-memory record `step_hydrate`
      # loaded and `step_save` will persist; `EntityElement.locate_chain`
      # mutates it in place exactly the way `EntityInterpreter`'s own
      # `step_locate_element`/`step_apply_mutations` mutate their OWN
      # freshly-loaded copy — the only difference is WHICH already-in-
      # memory record gets handed in.
      def step_delegate_to_entity(ctx)
        delegation = ctx.command.mutations.find { |mutation| mutation.op == :delegate }
        return unless delegation

        step(:delegate_to_entity) {
          entity_name, _dot, command_name = delegation.target.to_s.rpartition(".")
          entity = ctx.aggregate.entities.find { |e| e.hecks_name == entity_name } ||
                   raise(WiringError, "#{ctx.command.hecks_name} delegates_to #{entity_name}." \
                                       "#{command_name}, but #{ctx.aggregate.hecks_name} has no " \
                                       "entity named #{entity_name.inspect}")
          target_command = entity.command(command_name) ||
                           raise(WiringError, "#{ctx.command.hecks_name} delegates_to " \
                                               "#{entity_name}.#{command_name}, which " \
                                               "#{entity_name} declares no such command")

          # `with:` REMAPS, it does not ENUMERATE — starting from a copy
          # of THIS command's own already-resolved args (`ctx.args`) and
          # overlaying the explicit mapping on top means ambient context
          # the caller never had to think about (the aggregate's own
          # identity, addressed the ordinary way to reach `MoveKnight` at
          # all) flows through to the target untouched, the same as it
          # always would for a caller dispatching the entity command
          # directly. Confirmed necessary, not a defensive guess: a real
          # downstream domain's own AdvancePly-on-Moved policy silently
          # failed to re-locate its OWN aggregate (`reaction_log`: "no
          # Game with label.value ..."), because the emitted event's
          # payload — built from `target_args` alone — never carried
          # `label` at all when `with:` named only `id`/`to`.
          target_args = ctx.args.merge(
            delegation.source.to_h { |target_key, source_key| [target_key.to_sym, ctx.args[source_key]] }
          )

          element = EntityElement.locate_chain(ctx.aggregate, [entity], ctx.instance, target_args, command_name)
          view = Instance.new(aggregate: entity, id: EntityElement.element_identity(entity, element).to_s, state: element)

          @rules.enforce_givens(view, target_command, target_args, domain: ctx.domain, declaring: entity, parent: ctx.instance)
          transition = @rules.admissible_transition(entity, target_command, view)

          old_element = target_command.ensures.empty? ? nil : element.dup
          target_command.mutations.each { |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, entity, element, mutation, target_args)
          }
          element[entity.lifecycle.field] = transition.target if transition

          settled = Instance.new(aggregate: entity, id: view.id, state: element)
          @rules.enforce_ensures(settled, target_command, target_args, old: old_element, domain: ctx.domain, parent: ctx.instance)

          ctx.delegated_events = @rules.emit(target_command, ctx.domain, ctx.aggregate, ctx.instance, target_args, ctx.repository)
        }
      end

      def step_enforce_ensures(ctx)
        step(:enforce_ensures) {
          @rules.enforce_ensures(ctx.instance, ctx.command, ctx.args, old: ctx.old_state, domain: ctx.domain)
        }
      end

      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      # `dry_run:` skips this — see Dispatcher#dry_run's own comment. The
      # same conditional-skip shape `step_assign_creation_attributes`
      # already has (`return unless ctx.command.creates?`), not a new
      # pattern: a step that does not apply this time traces nothing,
      # rather than a caller having to branch around it.
      def step_save(ctx)
        return if ctx.dry_run

        step(:save) { ctx.repository.save(ctx.instance) }
      end

      # A DELEGATING COMMAND EMITS NOTHING OF ITS OWN (`CommandBuilder#build`'s
      # own guard refuses declaring `emits` alongside `delegates_to`) — its
      # result IS whatever `step_delegate_to_entity` already collected from
      # the target entity command's own `emits`, not a second, empty call
      # into `@rules.emit` for a command with no announced events at all.
      #
      # `dry_run:` skips this too, same reasoning as `step_save` — nothing
      # was committed, so `ctx.result` stays nil and `Dispatcher#dry_run`
      # never reads it (its own return value is just whether this raised).
      def step_emit(ctx)
        return if ctx.dry_run

        ctx.result = step(:emit) {
          # `ctx.delegated_events` is only ever set by `step_delegate_to_entity`,
          # and only when this command carries a `:delegate` mutation — an
          # empty Array (the target genuinely emitted nothing) is still
          # truthy in Ruby, so this reads correctly either way.
          next ctx.delegated_events if ctx.delegated_events

          @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository, ctx.correlation)
        }
      end

      def hydrate(repository, aggregate, command, args)
        if command.creates?
          # NOTHING IS MINTED. An identity that is invented is neither derived
          # from the record nor permanently associated with it — this used to
          # mint a random hex, so the same dispatch was not even stable across
          # two runs of itself. A store written yesterday could not be
          # reasoned about today.
          #
          # So a creating command that cannot say WHICH ONE THIS IS is refused,
          # and an aggregate with no `identified_by` must be told. Mutation
          # testing found this the other way round : the only two declarations
          # in banking whose removal changed observable dispatch behaviour
          # were both `identified_by`, and they changed it because removing
          # them fell through to here.
          id = identity_of(aggregate, args) ||
               raise(NotFound, RefusalWording.render("NotFound", "creating_no_identity",
                                                     command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                     identity: identity_reading(aggregate)))
          # A SECOND CREATION IS NOT A FRESH ONE. Nothing here checked whether
          # the derived id already named a record, so the same creating
          # command dispatched twice with the same identity silently built a
          # SECOND `Instance` and overwrote the first at save — the tenant a
          # box was rented to, gone without a refusal. A branch and box
          # number are a small, finite set a caller can collide with by
          # mistake in a way a minted reference cannot.
          if repository.find(id)
            raise(AlreadyExists, RefusalWording.render("AlreadyExists", "creating_duplicate",
                                                       command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                       identity: identity_reading(aggregate),
                                                       offered: Rendering.describe(id)))
          end

          Instance.new(aggregate: aggregate, id: id)
        else
          # A COMMAND THAT ACTS ON A RECORD MAY NAME IT BY THE ID IT DERIVED.
          #
          # This is not the fallback coming back. The fallback MINTED an identity for
          # an aggregate that declared none ; this names an aggregate whose identity is
          # declared and already derived, by the answer that derivation gave. A caller
          # holding a record's id — a walk that just declared it, a saga carrying it
          # forward — should not have to take the identity apart to say which one it
          # means. A CREATING command gets no such courtesy : it must derive, because
          # there is no record yet whose id could be quoted back.
          id = identity_of(aggregate, args) ||
               identity_from(aggregate, args, :id) ||
               identity_from(aggregate, args, reference_key(command)) ||
               raise(NotFound, RefusalWording.render("NotFound", "acting_no_identity",
                                                     command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                     identity: identity_reading(aggregate)))
          found = repository.find(id) ||
                  raise(NotFound, RefusalWording.render("NotFound", "record_missing",
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate),
                                                        offered:   Rendering.describe(id)))
          found.dup
        end
      end

      # THE JOIN, THE DIG, AND THE READING — all shared with `EntityInterpreter`
      # now, in `Runtime::Identity`, rather than kept as two copies that could
      # only ever drift. See that module for the reasoning ; these three stay
      # here, at the old names, purely so nothing below has to change.
      def identity_of(aggregate, args)   = Identity.of(aggregate, args)
      def identity_from(aggregate, args, key) = Identity.from(aggregate, args, key)
      def identity_reading(construct)    = Identity.reading(construct)
    end
  end
end
