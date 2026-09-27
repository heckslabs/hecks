require_relative "interpreting"
require_relative "../naming"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "value"
require_relative "refusal_wording"
require_relative "invocation"
require_relative "dependency_planning"
require_relative "../ports/persistence/execution"
require_relative "entity_element"
require_relative "command_interpreter/argument_gate"

module Hecks
  module Runtime
    # Interprets a command dispatched against a nested entity (a dotted verb
    # like "Handler.Dispatch.Bind") rather than an aggregate root directly.
    # CommandInterpreter's sibling for entity-owned commands.
    class EntityInterpreter
      include Interpreting
      # Same argument gate aggregate commands and port operations run —
      # without it, entity commands skip unknown/absent-argument checks.
      include CommandInterpreter::ArgumentGate

      attr_reader :registry

      # The command-execution steps, in order, generated from
      # Vocabulary::EntityDispatchOrder. Never includes
      # `assign_creation_attributes` — an entity is never created directly.
      DISPATCH_ORDER = Hecks::Vocabulary.symbols("EntityDispatchOrder")

      # Retry cap for a stale write — same reasoning as
      # `CommandInterpreter::MAX_STALE_WRITE_RETRIES`.
      MAX_STALE_WRITE_RETRIES = 5

      # `chain` holds every entity a dotted verb passes through, root-first
      # (ADR 0026); `entity`/`entity_name` are always its last entry, the one
      # a command targets. `instance` is the parent aggregate record;
      # `element`/`view` are the entity piece itself, pre- and
      # post-mutation. `:chain` intentionally shadows Enumerable#chain —
      # every read is the struct field, never enumerable-combining.
      # rubocop:disable-next Lint/StructNewOverride
      Context = Struct.new(:domain, :aggregate, :entity, :entity_name, :command, :command_name,
                           :args, :repository, :instance, :chain, :element, :view, :transition,
                           :old_element, :result, :route, :plan, :persistence_outcome, :dry_run, :outbox_rows,
                           :correction_bindings, :invocation)

      # A dotted entity verb resolved against its aggregate: the entity
      # chain it names and the command located at the end of it.
      Resolution = Data.define(:entity_names, :chain, :command_name, :command) do
        # Resolves a dotted entity verb into its entity chain and command,
        # raising UnknownVerb if either segment doesn't exist.
        def self.of(aggregate, dotted)
          *entity_names, command_name = dotted.to_s.split(".")
          if entity_names.empty?
            raise UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                          aggregate: aggregate.hecks_name, entity: dotted.to_s)
          end

          chain = walk(aggregate, entity_names)
          command = chain.last.command(command_name) ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_no_command",
                                                                  entity: chain.last.hecks_name, command: command_name))
          new(entity_names: entity_names, chain: chain, command_name: command_name, command: command)
        end

        # Walks one hop per dotted segment, resolving each entity name off
        # the previous one — not limited to two levels.
        def self.walk(aggregate, entity_names)
          owner = aggregate
          entity_names.map do |name|
            found = owner.entities.find { |piece| piece.hecks_name == name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                                  aggregate: owner.hecks_name, entity: name))
            owner = found
            found
          end
        end
        private_class_method :walk
      end

      # @param registry [Runtime::Registry] the booted registry this interpreter reads
      # @param rules [Runtime::CommandRules] the shared rules engine (admissibility,
      #   references, arithmetic, authorization, emission) dispatch runs through
      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # Runs the entity dispatch order for one command, saving and emitting
      # through the parent record. Retries once on `StaleWrite` with a fresh
      # `ctx`, re-reading current state.
      # @param domain [String, Symbol] the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the root aggregate owning the entity chain
      # @param resolution [EntityInterpreter::Resolution] the resolved entity chain and command
      # @param invocation [Runtime::Invocation] the invocation `Dispatcher` built
      # @param dry_run [Boolean] validate every step without saving, emitting or enqueueing
      # @return [Array(Runtime::Instance, Array<Runtime::Event>, Runtime::DependencyPlanning::Plan,
      #   Ports::Persistence::Execution, Array<Runtime::Outbox::Row>)] instance, events, plan,
      #   persistence outcome and outbox rows — last three nil on a dry run
      # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class when a rule refuses
      # @raise [Runtime::StaleWrite] if writers race through every retry
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, aggregate, resolution, invocation, dry_run: false)
        chain        = resolution.chain
        entity       = chain.last
        command      = resolution.command
        command_name = resolution.command_name
        route        = invocation.target
        args         = invocation.to_args
        attempt = 0
        begin
          ctx = Context.new(domain, aggregate, entity, resolution.entity_names.join("."), command, command_name, args)
          ctx.invocation = invocation
          ctx.chain = chain
          ctx.route = route
          ctx.dry_run = dry_run
          # `root_aggregate:` is the true root aggregate (this method's first
          # parameter), never `entity` — a `parent.X` read in this command's
          # given/ensures means the root's field, not the entity's.
          ctx.plan = DependencyPlanning::Analyzer.call(aggregate: entity, command: command, root_aggregate: aggregate)
          # Resolved once, here — `step_hydrate_parent` reuses `ctx.repository`
          # rather than re-fetching it.
          ctx.repository = @registry.repository(domain, aggregate)
          lock_id = Identity.best_effort(aggregate, args, route)
          run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
          [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome, ctx.outbox_rows]
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
      end

      private

      # No-op — entities have no `decode_arguments` step of their own.
      def step_decode_arguments(_ctx); end

      # `extra_identity_heads:` covers every entity in `ctx.chain`, not just
      # the root — each hop is addressed by its own identity fields, which
      # would otherwise be refused as unknown arguments.
      def step_refuse_unknown_arguments(ctx)
        step(:refuse_unknown_arguments) do
          refuse_unknown_arguments(ctx.domain, ctx.aggregate, ctx.command, ctx.args,
                                   extra_identity_heads: ctx.chain.flat_map(&:identity_heads))
        end
      end

      # No `aggregate:` exemption needed — an entity command's chain identity
      # never reaches `command.attributes` in the first place.
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

      def step_hydrate_parent(ctx)
        # `ctx.repository` is resolved once, in `#call`, before the
        # isolation decision — not here.
        ctx.instance = step(:hydrate_parent) do
          parent(ctx.repository, ctx.aggregate, ctx.entity_name, ctx.command_name, ctx.args, ctx.route)
        end
      end

      def step_locate_element(ctx)
        ctx.element = step(:locate_element) do
          EntityElement.locate_chain(ctx.aggregate, ctx.chain, ctx.instance, ctx.args, ctx.command_name, ctx.route)
        end
        # `view` was hydrated once, here, into its own state hash
        # (Value.hydrate builds a fresh Hash — never aliased with `element`)
        # — exactly right for enforce_givens, which must read pre-mutation.
        ctx.view = Instance.new(aggregate: ctx.entity, id: EntityElement.element_identity(ctx.entity, ctx.element).to_s,
                                state: ctx.element)
      end

      # Enforces this command's `given`s and correction-target admissibility.
      # Checked against the parent aggregate, never the entity view — every
      # emitted event is stamped with the root aggregate's name and the
      # parent record's id, regardless of dispatch level.
      def step_enforce_givens(ctx)
        step(:enforce_givens) do
          ctx.correction_bindings = @rules.enforce_correction_target(ctx.instance, ctx.aggregate, ctx.command, domain: ctx.domain)
          @rules.enforce_givens(ctx.view, ctx.command, ctx.args, domain: ctx.domain, declaring: ctx.entity, parent: ctx.instance,
                                correction: ctx.correction_bindings)
        end
      end

      def step_admissible_transition(ctx)
        ctx.transition = step(:admissible_transition) { @rules.admissible_transition(ctx.entity, ctx.command, ctx.view) }
      end

      def step_apply_mutations(ctx)
        ctx.old_element = ctx.element.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) do
          pre = ctx.element.dup # the update set reads the element as it stood before mutation
          ctx.command.mutations.each do |mutation|
            EntityElement.apply_to_element(@rules, ctx.aggregate, ctx.entity, ctx.element, mutation, ctx.args, pre)
          end
        end
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.element[ctx.entity.lifecycle.field] = ctx.transition.target }
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
          @rules.enforce_ensures(settled, ctx.command, ctx.args, old: ctx.old_element, domain: ctx.domain, parent: ctx.instance,
                                 correction: ctx.correction_bindings || {})
        end
      end

      # Enforces the parent aggregate's own invariants — there is no separate
      # "entity invariant" concept (ADR 0025 scopes `invariant` to the aggregate).
      def step_enforce_invariants(ctx)
        step(:enforce_invariants) { @rules.enforce_invariants(ctx.instance, ctx.aggregate, domain: ctx.domain) }
      end

      # `dry_run:` skips only the persist — the reference-existence check
      # above stays unconditional either way.
      def step_save(ctx)
        step(:save) { @rules.resolve_state_references(ctx.domain, ctx.aggregate, ctx.instance.state) }

        return if ctx.dry_run

        step(:save) do
          # `expected_version:` is nil for a non-CAS repository or an instance
          # never read from storage — either falls through to a plain save.
          ctx.persistence_outcome = ctx.repository.save(ctx.instance, expected_version: ctx.instance.version)
          if ctx.persistence_outcome.status == :stale
            # Intentionally not a `RefusalWording.render` call — see
            # `Runtime::StaleWrite`'s own comment.
            raise(StaleWrite,
                  "#{ctx.command.hecks_name} on #{ctx.aggregate.hecks_name} " \
                  "(#{Identity.reading(ctx.aggregate)}: #{Rendering.describe(ctx.instance.id)}) lost a race — " \
                  "another write committed against this record after it was read")
          end
        end
      end

      # `dry_run:` skips this too — nothing was committed, so `ctx.result`
      # stays nil and `Dispatcher#dry_run?` never reads it.
      def step_emit(ctx)
        return if ctx.dry_run

        ctx.result = step(:emit) { @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository) }
      end

      # Finds the parent aggregate: the declared identity first, then a bare
      # `id:` for a record the caller derived itself.
      def parent(repository, aggregate, entity_name, command_name, args, route = nil)
        parent_id = route&.aggregate ||
                    Identity.of(aggregate, args) ||
                    Identity.from(aggregate, args, :id) ||
                    raise(NotFound, RefusalWording.render_site("NotFound", "entity_parent_no_identity",
                                                               command: command_name, aggregate: aggregate.hecks_name,
                                                               entity: entity_name, identity: Identity.reading(aggregate)))
        found = repository.find(parent_id) ||
                raise(NotFound, RefusalWording.render_site("NotFound", "record_missing",
                                                           aggregate: aggregate.hecks_name,
                                                           identity:  Identity.reading(aggregate),
                                                           offered:   Rendering.describe(parent_id)))
        found.dup
      end

      # Entity element helpers (`locate_chain`, `element_of`, `element_identity`,
      # `apply_to_element`) live in `Runtime::EntityElement`, shared with
      # `CommandInterpreter#delegate_to_entity`.
    end
  end
end
