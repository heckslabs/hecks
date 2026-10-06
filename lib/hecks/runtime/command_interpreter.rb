require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "command_interpreter/enforcement"
require_relative "command_interpreter/hydration"
require_relative "command_interpreter/persisting"
require_relative "command_interpreter/delegation"
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
    # gate, mutation walk, hydration, delegation and save are mixed in from
    # their own files.
    class CommandInterpreter
      include Interpreting
      include ArgumentGate
      include MutationApplier
      include Enforcement
      include Hydration
      include Persisting
      include Delegation

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

      # Dispatches `command` through the declared step order, retrying once per write conflict.
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
      # rubocop:disable-next Metrics/ParameterLists -- the public dispatch signature every door calls
      def call(domain, aggregate, command, invocation, correlation = nil, dry_run: false)
        args     = invocation.to_args
        settings = { invocation: invocation, route: invocation.target, correlation: correlation, dry_run: dry_run }
        attempt  = 0
        begin
          dispatch_once(new_context(domain, aggregate, command, args, settings))
        rescue StaleWrite
          attempt += 1
          retry if attempt < MAX_STALE_WRITE_RETRIES
          raise
        end
      end

      private

      # A fresh context for one attempt, its plan and repository resolved up front.
      def new_context(domain, aggregate, command, args, settings)
        ctx = Context.new(domain, aggregate, command, args)
        ctx.invocation  = settings[:invocation]
        ctx.correlation = settings[:correlation]
        ctx.route       = settings[:route]
        ctx.dry_run     = settings[:dry_run]
        ctx.plan        = DependencyPlanning::Analyzer.call(aggregate: aggregate, command: command)
        # Resolved once here, before hydration: `Registry#repository` memoizes,
        # and the isolation decision needs its capabilities up front.
        ctx.repository  = @registry.repository(domain, aggregate)
        ctx
      end

      def dispatch_once(ctx)
        lock_id = Identity.best_effort(ctx.aggregate, ctx.args, ctx.route, reference_key: reference_key(ctx.command))
        run_dispatch_order_with_isolation(DISPATCH_ORDER, ctx, lock_key_id: lock_id)
        [ctx.instance, ctx.result, ctx.plan, ctx.persistence_outcome, ctx.outbox_rows]
      end

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
        ctx.instance = step(:hydrate) { hydrate_for(ctx) }
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
        step(:apply_mutations) { apply_all_mutations(ctx) }
      end

      # One update set over the pre-dispatch state (C4.2, docs/
      # semantics/bluebook-semantics.md): every effect's sources read
      # `pre` — the state as it was before this command — and its
      # target is written to the candidate; declaration order carries
      # no meaning, and build refuses a field written twice.
      def apply_all_mutations(ctx)
        pre = ctx.instance.state.dup
        ctx.command.mutations.each do |mutation|
          apply(ctx.instance, ctx.aggregate, mutation, ctx.args, pre)
        end
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.instance[ctx.aggregate.lifecycle.field] = ctx.transition.target }
      end

      # A delegating command emits nothing of its own; its result is the
      # target entity command's own `emits`, parked by
      # `step_delegate_to_entity` and emitted here, after save (C7.2).
      # `dry_run:` skips this too — nothing was committed, so `ctx.result`
      # stays nil.
      def step_emit(ctx)
        return if ctx.dry_run

        ctx.result = step(:emit) { emit_events(ctx) }
      end

      # `ctx.pending_delegation` is only ever set by `step_delegate_to_entity`, and only when this
      # command carries a `:delegate` mutation. The same dispatch, so the same correlation —
      # without threading `ctx.correlation` through, a saga-driven door's events would lose their
      # stamp here.
      def emit_events(ctx)
        command, args = ctx.pending_delegation || [ctx.command, ctx.args]
        @rules.emit(command, ctx.domain, ctx.aggregate, ctx.instance, args, ctx.repository, ctx.correlation)
      end
    end
  end
end
