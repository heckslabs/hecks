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
require_relative "entity_interpreter/resolution"
require_relative "entity_interpreter/locating"
require_relative "entity_interpreter/enforcement"
require_relative "entity_interpreter/saving"

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
      include Locating
      include Enforcement
      include Saving

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
                           :correction_bindings, :invocation, keyword_init: true)

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
      # @return [Array] instance, events, plan, persistence outcome, outbox rows — last three
      #   nil on a dry run
      # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class when a rule refuses
      # @raise [Runtime::StaleWrite, Runtime::WiringError] every retry loses, or resolve fails
      def call(domain, aggregate, resolution, invocation, dry_run: false)
        settings = { invocation: invocation, route: invocation.target, dry_run: dry_run }
        args     = invocation.to_args
        attempt  = 0
        begin
          dispatch_once(new_context(domain, aggregate, resolution, args, settings))
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
      end

      private

      # A fresh context for one attempt, its plan and repository resolved up front.
      def new_context(domain, aggregate, resolution, args, settings)
        chain = resolution.chain
        ctx = Context.new(domain: domain, aggregate: aggregate, entity: chain.last, chain: chain, args: args,
                          entity_name: resolution.entity_names.join("."), command: resolution.command,
                          command_name: resolution.command_name, **settings)
        ctx.plan       = planned(ctx)
        # Resolved once, here — `step_hydrate_parent` reuses `ctx.repository`
        # rather than re-fetching it.
        ctx.repository = @registry.repository(domain, aggregate)
        ctx
      end

      # `root_aggregate:` is the true root aggregate (the dispatch's own aggregate),
      # never `entity` — a `parent.X` read in this command's given/ensures means the root's
      # field, not the entity's.
      def planned(ctx)
        DependencyPlanning::Analyzer.call(aggregate: ctx.entity, command: ctx.command, root_aggregate: ctx.aggregate)
      end

      def dispatch_once(ctx)
        lock_id = Identity.best_effort(ctx.aggregate, ctx.args, ctx.route)
        run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
        [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome, ctx.outbox_rows]
      end

      # Answers the outside facts the entity command `needs`, as the aggregate interpreter does;
      # the arguments are otherwise already decoded.
      def step_decode_arguments(ctx)
        ctx.args = enrich_arguments(ctx.command, ctx.args)
      end

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

      def step_apply_mutations(ctx)
        ctx.old_element = ctx.element.dup unless ctx.command.ensures.empty?
        step(:apply_mutations) { mutate_element(ctx) }
      end

      def mutate_element(ctx)
        pre = ctx.element.dup # the update set reads the element as it stood before mutation
        ctx.command.mutations.each do |mutation|
          EntityElement.apply_to_element(@rules, ctx.aggregate, ctx.entity, ctx.element, mutation, ctx.args, pre)
        end
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.element[ctx.entity.lifecycle.field] = ctx.transition.target }
      end

      # Entity element helpers (`locate_chain`, `element_of`, `element_identity`,
      # `apply_to_element`) live in `Runtime::EntityElement`, shared with
      # `CommandInterpreter#delegate_to_entity`.
    end
  end
end
