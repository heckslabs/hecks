require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "dependency_planning"
require_relative "../ports/persistence/execution"
require_relative "instance"
require_relative "refusal_wording"
require_relative "entity_element"

module Hecks
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
      DISPATCH_ORDER = Hecks::Vocabulary.symbols("AggregateDispatchOrder")

      # A LAST-RESORT SAFETY VALVE, NOT THE NORMAL OUTCOME PATH — see
      # `Runtime::StaleWrite`'s own comment. Two concurrent writers
      # against one aggregate resolve through exactly one retry in the
      # ordinary case (the loser's retried hydrate reads the winner's now-
      # committed state and its own `given` refuses for real, raising
      # `GivenNotMet`, not `StaleWrite`) — this cap exists for pathological
      # contention (many concurrent writers on one hot aggregate), not the
      # two-writer case.
      MAX_STALE_WRITE_RETRIES = 5

      # EVERY CROSS-STEP LOCAL `call` used to thread through its own literal
      # sequence, held in one place now that the sequence is data-driven —
      # `result` and `transition`/`old_state` default to nil until the step
      # that sets them runs, same as they were unset locals before that point.
      Context = Struct.new(:domain, :aggregate, :command, :args, :repository, :instance, :transition, :old_state,
                           :result, :correlation, :route, :plan, :strategy, :persistence_outcome, :delegated_events,
                           :dry_run)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # `dry_run:` — Dispatcher#dry_run?'s own entry point. Every step up
      # through enforce_ensures/enforce_invariants runs exactly as a real
      # dispatch would (givens checked, mutations applied to `ctx.instance`
      # in memory); `step_save`/`step_emit` are the only two that read this
      # flag, each skipping its own real work — see their own comments.
      # RETRIES THE WHOLE METHOD BODY on `StaleWrite` — a fresh `ctx`, a
      # fresh `step_hydrate` re-reading current state, so `enforce_givens`
      # re-evaluates against reality rather than the snapshot that just
      # went stale. See `MAX_STALE_WRITE_RETRIES`/`Runtime::StaleWrite`
      # for why exhaustion is a pathological-contention signal, not the
      # expected shape of a two-writer race.
      def call(domain, aggregate, command, args, correlation = nil, route: nil, dry_run: false)
        attempt = 0
        begin
          ctx = Context.new(domain, aggregate, command, args)
          ctx.correlation = correlation
          ctx.route = route
          ctx.dry_run = dry_run
          ctx.plan = DependencyPlanning::Analyzer.call(aggregate: aggregate, command: command)
          # RESOLVED HERE, ONCE, BEFORE HYDRATION — `Registry#repository`
          # memoizes, so this and `step_hydrate`'s own read of `ctx.repository`
          # (no second fetch there any more) always name the same instance;
          # the isolation decision below (lock vs. CAS+retry) needs the
          # repository's capabilities before a single step runs.
          ctx.repository = @registry.repository(domain, aggregate)
          lock_id = Identity.best_effort(aggregate, args, route, reference_key: reference_key(command))
          run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
          [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome]
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
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
        # `ctx.repository` is resolved once, in `#call`, before the
        # isolation decision (lock vs. CAS+retry) — not here any more.
        ctx.strategy = ctx.plan.strategy_for(capabilities: ctx.repository.capabilities)
        ctx.instance = step(:hydrate) {
          if ctx.plan.complete_state? && ctx.plan.state_independent?
            hydrate_complete_state(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route, ctx.strategy)
          elsif ctx.plan.complete_state?
            hydrate_prior_or_initial(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          elsif legacy_implicit_creation?(ctx)
            hydrate_legacy_creation(ctx.repository, ctx.aggregate, ctx.command, ctx.args)
          else
            hydrate_existing(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          end
        }
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) {
          # STRUCTURAL, before the declared givens — the same ordering
          # NotFound/AlreadyExists already get at hydration: "does the
          # fact this command's corrects names even exist" is not a
          # domain rule an author wrote, it is a precondition for the
          # domain rules to mean anything at all.
          @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command, domain: ctx.domain)
          @rules.enforce_givens(ctx.instance, ctx.command, ctx.args, domain: ctx.domain,
                                declaring: ctx.aggregate, parent: ctx.instance)
        }
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.aggregate, ctx.command, ctx.instance) }
      end

      def step_assign_creation_attributes(ctx)
        return unless legacy_implicit_creation?(ctx)

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
          @rules.enforce_ensures(ctx.instance, ctx.command, ctx.args, old: ctx.old_state,
                                 domain: ctx.domain, parent: ctx.instance)
        }
      end

      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      # `dry_run:` skips this — see Dispatcher#dry_run?'s own comment. The
      # same conditional-skip shape `step_assign_creation_attributes`
      # already has (`return unless ctx.command.creates?`), not a new
      # pattern: a step that does not apply this time traces nothing,
      # rather than a caller having to branch around it.
      def step_save(ctx)
        return if ctx.dry_run

        step(:save) do
          @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state)
          ctx.persistence_outcome = if ctx.strategy == DependencyPlanning::ATOMIC_PUT
                                      # A SECOND CREATION IS NOT A FRESH ONE — see
                                      # hydrate_legacy_creation's own comment; the
                                      # same refusal, on the same terms, for the
                                      # complete-state path. `insert_only:` asks the
                                      # ADAPTER to decide and refuse ATOMICALLY
                                      # (never writing a `creates?` command over an
                                      # identity that already names a record) rather
                                      # than this interpreter reading the record
                                      # first to check — a `repository.find` before
                                      # every atomic_put would be exactly the read
                                      # this strategy exists to skip.
                                      ctx.repository.atomic_put(ctx.instance, insert_only: ctx.command.creates?)
                                    else
                                      # `expected_version:` is `ctx.instance.version` — nil for a
                                      # brand-new record (never read from storage) or when the
                                      # repository isn't CAS-capable, either of which falls straight
                                      # through to a plain, unconditional save inside `AppendOnly#save`.
                                      ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
                                    end
          if ctx.persistence_outcome.status == :conflicted
            raise(AlreadyExists, RefusalWording.render("AlreadyExists", "creating_duplicate",
                                                       command: ctx.command.hecks_name, aggregate: ctx.aggregate.hecks_name,
                                                       identity: identity_reading(ctx.aggregate),
                                                       offered: Rendering.describe(ctx.instance.id)))
          elsif ctx.persistence_outcome.status == :stale
            # NOT a `RefusalWording.render` call — this is not a declared
            # vocabulary refusal, just a plain, informative message. See
            # `Runtime::StaleWrite`'s own comment: caught by `#call`'s
            # retry loop, re-raised only once retries are exhausted.
            raise(StaleWrite,
                  "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
                  "(#{identity_reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
                  "another write committed against this record after it was read")
          end
        end
      end

      # A DELEGATING COMMAND EMITS NOTHING OF ITS OWN (`CommandBuilder#build`'s
      # own guard refuses declaring `emits` alongside `delegates_to`) — its
      # result IS whatever `step_delegate_to_entity` already collected from
      # the target entity command's own `emits`, not a second, empty call
      # into `@rules.emit` for a command with no announced events at all.
      #
      # `dry_run:` skips this too, same reasoning as `step_save` — nothing
      # was committed, so `ctx.result` stays nil and `Dispatcher#dry_run?`
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

      def hydrate_existing(repository, aggregate, command, args, route = nil)
        if route
          found = repository.find(route.aggregate) ||
                  raise(NotFound, RefusalWording.render("NotFound", "record_missing",
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate),
                                                        offered:   Rendering.describe(route.aggregate)))
          return found.dup
        end

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

      # Transitional compatibility for live source that has not yet acquired
      # explicit effects. It is deliberately isolated from the normal routing
      # and planning path so `reference_to` no longer chooses how a migrated
      # command hydrates or persists. Wave 8 removes this after the inventory is
      # empty; frozen eras retain their own shadow parser.
      #
      # `ctx.plan.complete_state?` already claimed every command whose plan is
      # fully resolved in the two branches above `step_hydrate` tries first, so
      # reaching this check already means the plan is incomplete — an
      # un-migrated command still routes here on `creates?` alone, the same as
      # the old `hydrate` did, regardless of whether it happens to have any
      # mutations (`write_set`). Requiring an EMPTY write_set here refused
      # every un-migrated creating command that sets even one field.
      def legacy_implicit_creation?(ctx)
        ctx.route.nil? && ctx.command.creates?
      end

      def hydrate_legacy_creation(repository, aggregate, command, args)
        id = identity_of(aggregate, args) ||
             raise(NotFound, RefusalWording.render("NotFound", "creating_no_identity",
                                                   command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                   identity: identity_reading(aggregate)))
        if repository.find(id)
          raise(AlreadyExists, RefusalWording.render("AlreadyExists", "creating_duplicate",
                                                     command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                     identity: identity_reading(aggregate),
                                                     offered: Rendering.describe(id)))
        end

        Instance.new(aggregate: aggregate, id: id, args: args)
      end

      def hydrate_complete_state(repository, aggregate, command, args, route, strategy)
        derived = identity_of(aggregate, args)
        if route && derived && route.aggregate.to_s != derived.to_s
          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        id = route&.aggregate || derived ||
             raise(NotFound, RefusalWording.render("NotFound", "creating_no_identity",
                                                   command:   command.hecks_name,
                                                   aggregate: aggregate.hecks_name,
                                                   identity:  identity_reading(aggregate)))

        # A SECOND CREATION IS NOT A FRESH ONE — see hydrate_legacy_creation's
        # own comment; the same refusal, on the same terms, for the
        # complete-state path. ONLY when `strategy` will NOT be ATOMIC_PUT:
        # an atomic-put-capable adapter enforces this itself, atomically,
        # via `insert_only:` in step_save (no read here, no race with the
        # write) — but `strategy_for` already fell back to a plain `save`
        # for an adapter with no atomic_put capability at all (Heki, today),
        # and a plain `save` never refuses an overwrite on its own. Skipping
        # this check for THAT case silently dropped the refusal instead of
        # deferring it — the very "no such call — no such check" gap Wave
        # 8 exists to close everywhere else.
        if command.creates? && strategy != DependencyPlanning::ATOMIC_PUT && repository.find(id)
          raise(AlreadyExists, RefusalWording.render("AlreadyExists", "creating_duplicate",
                                                     command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                     identity: identity_reading(aggregate),
                                                     offered: Rendering.describe(id)))
        end

        Instance.new(aggregate: aggregate, id: id, args: args)
      end

      # A complete command may still depend on prior state: lifecycle guards
      # are the common case. Read once so an existing record is checked against
      # its real state; when no record exists, the aggregate's declared defaults
      # are the prior state. Completeness, not a reference marker, proves that
      # initializing that missing record is safe.
      def hydrate_prior_or_initial(repository, aggregate, command, args, route)
        derived = identity_of(aggregate, args)
        if route && derived && route.aggregate.to_s != derived.to_s
          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        id = route&.aggregate || derived ||
             raise(NotFound, RefusalWording.render("NotFound", "creating_no_identity",
                                                   command:   command.hecks_name,
                                                   aggregate: aggregate.hecks_name,
                                                   identity:  identity_reading(aggregate)))
        found = repository.find(id)

        # A SECOND CREATION IS NOT A FRESH ONE — see hydrate_legacy_
        # creation's own comment; the same refusal, on the same terms, for
        # a complete-but-state-dependent command (one with a `given`
        # reading its own prior state, which is what routes here instead
        # of hydrate_complete_state). Gated on `command.creates?`: a
        # NON-creating command's own complete payload legitimately means
        # "act on whatever this identity already holds" (`found` IS the
        # prior state this branch exists to supply), so only a genuine
        # creation reusing an already-occupied identity is a duplicate.
        # `SafeDepositBox.Rent` is exactly this shape — `given("box is
        # vacant")` makes it state-dependent, so a second Rent used to
        # silently hydrate the existing box as "prior state" and refuse
        # for the wrong reason (not vacant) instead of the right one
        # (already exists).
        if found && command.creates?
          raise(AlreadyExists, RefusalWording.render("AlreadyExists", "creating_duplicate",
                                                     command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                     identity: identity_reading(aggregate),
                                                     offered: Rendering.describe(id)))
        end

        found ? found.dup : Instance.new(aggregate: aggregate, id: id, args: args)
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
