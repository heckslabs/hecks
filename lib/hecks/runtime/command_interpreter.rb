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
require_relative "rebuild_sweep"

module Hecks
  module Runtime
    # The dispatch pipeline for a command on an aggregate head; the argument
    # gate and mutation walk are mixed in from their own files.
    class CommandInterpreter
      include Interpreting
      include ArgumentGate
      include MutationApplier

      attr_reader :registry

      # Read off the generated table (lib/hecks/vocabulary.rb), not typed here.
      # spec/vocabulary_conformance_spec.rb holds every step to a real
      # `step_<name>` handler, both directions.
      DISPATCH_ORDER = Hecks::Vocabulary.symbols("AggregateDispatchOrder")

      # A cap for pathological contention (many concurrent writers on one hot
      # aggregate) — the ordinary two-writer race resolves in a single retry.
      MAX_STALE_WRITE_RETRIES = 5

      # Every cross-step local held in one place; fields default to nil until
      # the step that sets them runs.
      Context = Struct.new(:domain, :aggregate, :command, :args, :repository, :instance, :transition, :old_state,
                           :result, :correlation, :route, :plan, :strategy, :persistence_outcome, :pending_delegation,
                           :dry_run, :correction_bindings, :outbox_rows, :invocation)

      # @param registry [Runtime::Registry] the booted registry this interpreter reads
      # @param rules [Runtime::CommandRules] the shared rules engine (admissibility,
      #   references, arithmetic, authorization, emission) dispatch runs through
      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # Dispatches `command` against `aggregate` through the declared step
      # order, retrying once per concurrent-write conflict.
      #
      # @param domain [String, Symbol] the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate the command acts on
      # @param command [Class] the command class (`Bluebook::Command` subclass) to dispatch
      # @param invocation [Runtime::Invocation] the invocation built for this call
      # @param correlation [Hash, nil] saga correlation stamped on emitted events, if any
      # @param dry_run [Boolean] validate every step without saving, emitting or enqueueing
      # @return [Array] the settled instance, events, plan, persistence outcome, and outbox rows
      # @raise [StandardError] a domain refusal (Runtime::DOMAIN_REFUSALS) when a rule refuses
      # @raise [Runtime::StaleWrite, Runtime::WiringError] every retry loses, or resolve fails
      def call(domain, aggregate, command, invocation, correlation = nil, dry_run: false)
        args    = invocation.to_args
        route   = invocation.target
        attempt = 0
        begin
          ctx = Context.new(domain, aggregate, command, args)
          ctx.invocation = invocation
          ctx.correlation = correlation
          ctx.route = route
          ctx.dry_run = dry_run
          ctx.plan = DependencyPlanning::Analyzer.call(aggregate: aggregate, command: command)
          # Resolved once here, before hydration: `Registry#repository` memoizes,
          # and the isolation decision below needs its capabilities up front.
          ctx.repository = @registry.repository(domain, aggregate)
          lock_id = Identity.best_effort(aggregate, args, route, reference_key: reference_key(command))
          run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
          [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome, ctx.outbox_rows]
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
      end

      private

      # `Routing` has already handed `call` a decoded argument hash, so the one thing left to do
      # here is answer the outside facts the command `needs`, before any refusal or given reads
      # its arguments. Not traced: the step has always been invisible to a trace observer.
      def step_decode_arguments(ctx)
        ctx.args = enrich_arguments(ctx.command, ctx.args)
      end

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
        # isolation decision (lock vs. CAS+retry) — not here.
        ctx.strategy = ctx.plan.strategy_for(capabilities: ctx.repository.capabilities)
        ctx.instance = step(:hydrate) do
          if ctx.plan.complete_state? && ctx.plan.state_independent?
            hydrate_complete_state(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route, ctx.strategy)
          elsif ctx.plan.complete_state?
            hydrate_prior_or_initial(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          elsif legacy_implicit_creation?(ctx)
            hydrate_legacy_creation(ctx.repository, ctx.aggregate, ctx.command, ctx.args)
          else
            hydrate_existing(ctx.repository, ctx.aggregate, ctx.command, ctx.args, ctx.route)
          end
        end
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) do
          # Structural check before the declared givens (same ordering as
          # NotFound/AlreadyExists at hydration). Also locates the correction
          # target, if `as:` named one, so `step_enforce_ensures` can reuse it.
          ctx.correction_bindings = @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command, domain: ctx.domain)
          @rules.enforce_givens(ctx.instance, ctx.command, ctx.args, domain: ctx.domain,
                                declaring: ctx.aggregate, parent: ctx.instance, correction: ctx.correction_bindings)
        end
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
        # ensures. A shallow dup suffices: mutations replace fields (set,
        # arithmetic via Value#with, append builds a new array), never
        # edit a held value in place.
        ctx.old_state = ctx.instance.state.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) do
          # One update set over the pre-dispatch state (C4.2, docs/
          # semantics/bluebook-semantics.md): every effect's sources read
          # `pre` — the state as it was before this command — and its
          # target is written to the candidate; declaration order carries
          # no meaning, and build refuses a field written twice.
          pre = ctx.instance.state.dup
          ctx.command.mutations.each do |mutation|
            apply(ctx.instance, ctx.aggregate, mutation, ctx.args, pre)
          end
        end
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.instance[ctx.aggregate.lifecycle.field] = ctx.transition.target }
      end

      # The synchronous cousin of a policy's own `trigger` (see
      # `CommandBuilder#delegates_to`). Runs between this command's own
      # mutations and its ensures/invariants/save, so a refusal here leaves
      # nothing committed on either side. Reimplements the entity pipeline
      # (givens, transition, mutations, ensures, emit) inline, to keep that
      # exact ordering in one place rather than threading state through
      # method boundaries as parameters.
      def step_delegate_to_entity(ctx)
        delegation = ctx.command.mutations.find { |mutation| mutation.op == :delegate }
        return unless delegation

        step(:delegate_to_entity) do
          entity, target_command, command_name = resolve_delegation_target(ctx, delegation)
          target_args = mapped_and_gated_delegation_args(ctx, delegation, entity, target_command)

          element = EntityElement.locate_chain(ctx.aggregate, [entity], ctx.instance, target_args, command_name)
          view = Instance.new(aggregate: entity, id: EntityElement.element_identity(entity, element).to_s, state: element)

          @rules.enforce_givens(view, target_command, target_args, domain: ctx.domain, declaring: entity, parent: ctx.instance)
          transition = @rules.admissible_transition(entity, target_command, view)

          old_element = target_command.ensures.empty? ? nil : element.dup
          pre = element.dup # C4.2 — the update set reads the element as it was
          target_command.mutations.each do |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, entity, element, mutation, target_args, pre)
          end
          element[entity.lifecycle.field] = transition.target if transition

          settled = Instance.new(aggregate: entity, id: view.id, state: element)
          @rules.enforce_ensures(settled, target_command, target_args, old: old_element, domain: ctx.domain, parent: ctx.instance)

          # Not emitted here — C7.2: a refused command records nothing, and
          # the parent's own ensures/invariants/save steps still run after
          # this one. Parked and emitted by `step_emit`, after the parent
          # commits, alongside every other command's events.
          ctx.pending_delegation = [target_command, target_args]
        end
      end

      # The entity and command a `delegates_to` mutation names, resolved once so
      # `step_delegate_to_entity` can read them as plain locals.
      def resolve_delegation_target(ctx, delegation)
        entity_name, _dot, command_name = delegation.target.to_s.rpartition(".")
        entity = ctx.aggregate.entities.find { |e| e.hecks_name == entity_name } ||
                 raise(WiringError, "#{ctx.command.hecks_name} delegates_to #{entity_name}." \
                                    "#{command_name}, but #{ctx.aggregate.hecks_name} has no " \
                                    "entity named #{entity_name.inspect}")
        target_command = entity.command(command_name) ||
                         raise(WiringError, "#{ctx.command.hecks_name} delegates_to " \
                                            "#{entity_name}.#{command_name}, which " \
                                            "#{entity_name} declares no such command")
        [entity, target_command, command_name]
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

        refuse_unknown_arguments(ctx.domain, ctx.aggregate, target_command, target_args,
                                 extra_identity_heads: entity.identity_heads)
        refuse_absent_arguments(target_command, target_args)
        normalize_args(ctx.aggregate, target_command, target_args)
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

      # `dry_run:` skips persistence, but not `resolve_state_references` or
      # the ATOMIC_PUT duplicate check (`check_dry_run_creates_duplicate`) —
      # both are validation, not persistence, and a real dispatch would
      # refuse on either before ever writing.
      def step_save(ctx)
        step(:save) { @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state) }

        if ctx.dry_run
          step(:save) { check_dry_run_creates_duplicate(ctx) }
          return
        end

        step(:save) do
          seed_projected_fields(ctx)
          ctx.persistence_outcome = persist_instance(ctx)
          raise_for_persistence_outcome!(ctx)
        end
      end

      # The only path, real or dry, that catches a `creates?` command reusing
      # an occupied identity under ATOMIC_PUT — `hydrate_complete_state`
      # deliberately defers this exact check to here.
      def check_dry_run_creates_duplicate(ctx)
        return unless ctx.strategy == DependencyPlanning::ATOMIC_PUT && ctx.command.creates?
        return unless ctx.repository.find(ctx.instance.id)

        raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                        command: ctx.command.hecks_name, aggregate: ctx.aggregate.hecks_name,
                                                        identity: identity_reading(ctx.aggregate),
                                                        offered: Rendering.describe(ctx.instance.id)))
      end

      def persist_instance(ctx)
        if ctx.strategy == DependencyPlanning::ATOMIC_PUT
          # `insert_only:` asks the adapter to refuse atomically rather than
          # this interpreter reading the record first to check — a
          # `repository.find` before every atomic_put would be exactly the
          # read this strategy exists to skip.
          ctx.repository.atomic_put(ctx.instance, insert_only: ctx.command.creates?)
        else
          # `expected_version:` is nil for a brand-new record or a
          # non-CAS repository, either of which falls through to a
          # plain, unconditional save inside `AppendOnly#save`.
          ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
        end
      end

      def raise_for_persistence_outcome!(ctx)
        if ctx.persistence_outcome.status == :conflicted
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: ctx.command.hecks_name, aggregate: ctx.aggregate.hecks_name,
                                                          identity: identity_reading(ctx.aggregate),
                                                          offered: Rendering.describe(ctx.instance.id)))
        elsif ctx.persistence_outcome.status == :stale
          # Not a declared vocabulary refusal, just a plain, informative
          # message — caught by `#call`'s retry loop, re-raised only once
          # retries are exhausted.
          raise(StaleWrite,
                "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
                "(#{identity_reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
                "another write committed against this record after it was read")
        end
      end

      # The one-time, synchronous half of `projects` (ADR 0025); `RebuildSweep`
      # is what keeps a projected field current afterward. Without seeding it
      # here, a freshly created record would read a nil projected field until
      # an operator ran a sweep, refusing commands that depend on it for no
      # real reason. Uses the same `RebuildSweep.remote_value` a sweep
      # computes, and runs only at save time, never as a live read mid-dispatch.
      def seed_projected_fields(ctx)
        return if ctx.aggregate.projected_fields.empty?

        ctx.aggregate.projected_fields.each do |field|
          value = RebuildSweep.remote_value(@registry, ctx.domain, ctx.aggregate, ctx.instance.state, field)
          next if value.nil?

          ctx.instance.state[field.name] = value
        end
      end

      # A delegating command emits nothing of its own; its result is the
      # target entity command's own `emits`, parked by
      # `step_delegate_to_entity` and emitted here, after save (C7.2).
      # `dry_run:` skips this too — nothing was committed, so `ctx.result`
      # stays nil.
      def step_emit(ctx)
        return if ctx.dry_run

        ctx.result = step(:emit) do
          # `ctx.pending_delegation` is only ever set by
          # `step_delegate_to_entity`, and only when this command carries a
          # `:delegate` mutation.
          if ctx.pending_delegation
            target_command, target_args = ctx.pending_delegation
            # The same dispatch, so the same correlation — without
            # threading `ctx.correlation` through, a saga-driven door's
            # events would lose their stamp here.
            next @rules.emit(target_command, ctx.domain, ctx.aggregate, ctx.instance, target_args, ctx.repository,
                             ctx.correlation)
          end

          @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository, ctx.correlation)
        end
      end

      def hydrate_existing(repository, aggregate, command, args, route = nil)
        if route
          found = repository.find(route.aggregate) ||
                  raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                             aggregate: aggregate.hecks_name,
                                                             identity:  identity_reading(aggregate),
                                                             offered:   Rendering.describe(route.aggregate)))
          return found.dup
        end

        id = identity_of(aggregate, args) ||
             identity_from(aggregate, args, :id) ||
             identity_from(aggregate, args, reference_key(command)) ||
             raise(NotFound, RefusalWording.render_site("NotFound", "acting_no_identity",
                                                        command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                        identity: identity_reading(aggregate)))
        found = repository.find(id) ||
                raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                           aggregate: aggregate.hecks_name,
                                                           identity:  identity_reading(aggregate),
                                                           offered:   Rendering.describe(id)))
        found.dup
      end

      # Transitional compatibility for a command that has not yet acquired
      # explicit effects — isolated from the normal routing/planning path so
      # `reference_to` does not choose how a migrated command hydrates. An
      # un-migrated command routes here on `creates?` alone, regardless of
      # whether it has any mutations; requiring an empty write_set here would
      # wrongly exclude one that sets fields.
      def legacy_implicit_creation?(ctx)
        ctx.route.nil? && ctx.command.creates?
      end

      def hydrate_legacy_creation(repository, aggregate, command, args)
        id = identity_of(aggregate, args) ||
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                        identity: identity_reading(aggregate)))
        if repository.find(id)
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
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
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command:   command.hecks_name,
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate)))

        # `creates?` on an occupied identity refuses (`AlreadyExists`), except
        # under ATOMIC_PUT: that adapter enforces the same refusal itself,
        # atomically, via `insert_only:` in `step_save` — reading here too
        # would race the write for nothing.
        if command.creates? && strategy != DependencyPlanning::ATOMIC_PUT && repository.find(id)
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        Instance.new(aggregate: aggregate, id: id, args: args)
      end

      # A complete command may still depend on prior state (lifecycle guards
      # are the common case) — read once, so an existing record is checked
      # against its real state rather than assumed defaults.
      def hydrate_prior_or_initial(repository, aggregate, command, args, route)
        derived = identity_of(aggregate, args)
        if route && derived && route.aggregate.to_s != derived.to_s
          raise TypeMismatch,
                "#{command.hecks_name} routes to #{route.aggregate.inspect}, but its identity facts name #{derived.inspect}"
        end

        id = route&.aggregate || derived ||
             raise(NotFound, RefusalWording.render_site("NotFound", "creating_no_identity",
                                                        command:   command.hecks_name,
                                                        aggregate: aggregate.hecks_name,
                                                        identity:  identity_reading(aggregate)))
        found = repository.find(id)

        # Same refusal as `hydrate_complete_state`, for a complete-but-state-
        # dependent command (one with a `given` on its own prior state).
        # Gated on `creates?`: a non-creating command's complete payload just
        # means "act on whatever this identity already holds".
        if found && command.creates?
          raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "creating_duplicate",
                                                          command: command.hecks_name, aggregate: aggregate.hecks_name,
                                                          identity: identity_reading(aggregate),
                                                          offered: Rendering.describe(id)))
        end

        found ? found.dup : Instance.new(aggregate: aggregate, id: id, args: args)
      end

      # Shared with `EntityInterpreter`, in `Runtime::Identity`, rather than
      # kept as two copies that could only ever drift; these three stay here,
      # under their old names, so nothing below has to change.
      def identity_of(aggregate, args)   = Identity.of(aggregate, args)
      def identity_from(aggregate, args, key) = Identity.from(aggregate, args, key)
      def identity_reading(construct)    = Identity.reading(construct)
    end
  end
end
