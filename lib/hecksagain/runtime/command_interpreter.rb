require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"
require_relative "refusal_wording"

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
      DISPATCH_ORDER = %i[
        refuse_unknown_arguments refuse_absent_arguments normalize_args
        resolve_references hydrate enforce_givens admissible_transition
        assign_creation_attributes apply_mutations advance_lifecycle
        enforce_ensures save emit
      ].freeze

      # EVERY CROSS-STEP LOCAL `call` used to thread through its own literal
      # sequence, held in one place now that the sequence is data-driven —
      # `result` and `transition`/`old_state` default to nil until the step
      # that sets them runs, same as they were unset locals before that point.
      Context = Struct.new(:domain, :aggregate, :command, :args, :repository, :instance, :transition, :old_state, :result)

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, command, args)
        ctx = Context.new(domain, aggregate, command, args)
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

      def step_resolve_references(ctx)
        step(:resolve_references) { @rules.resolve_references(ctx.domain, ctx.command, ctx.args) }
      end

      def step_hydrate(ctx)
        ctx.repository = @registry.repository(ctx.domain, ctx.aggregate)
        ctx.instance = step(:hydrate) { hydrate(ctx.repository, ctx.aggregate, ctx.command, ctx.args) }
      end

      def step_enforce_givens(ctx)
        step(:enforce_givens) { @rules.enforce_givens(ctx.instance, ctx.command, ctx.args) }
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
        step(:apply_mutations) { ctx.command.mutations.each { |mutation| apply(ctx.instance, ctx.aggregate, mutation, ctx.args) } }
      end

      def step_advance_lifecycle(ctx)
        return unless ctx.transition

        step(:advance_lifecycle) { ctx.instance[ctx.aggregate.lifecycle.field] = ctx.transition.target }
      end

      def step_enforce_ensures(ctx)
        step(:enforce_ensures) { @rules.enforce_ensures(ctx.instance, ctx.command, ctx.args, old: ctx.old_state) }
      end

      def step_save(ctx)
        step(:save) { ctx.repository.save(ctx.instance) }
      end

      def step_emit(ctx)
        ctx.result = step(:emit) { @rules.emit(ctx.command, ctx.domain, ctx.aggregate, ctx.instance, ctx.args, ctx.repository) }
      end

      def hydrate(repository, aggregate, command, args)
        if command.creates?
          # NOTHING IS MINTED. An identity that is invented is neither derived
          # from the record nor permanently associated with it — Ruby minted a
          # random hex and Rust a counter, so the same dispatch produced two
          # different records, and Ruby's was not even stable across two runs of
          # itself. A store written yesterday could not be reasoned about today.
          #
          # So a creating command that cannot say WHICH ONE THIS IS is refused,
          # and an aggregate with no `identified_by` must be told. bin/undeclared
          # found this the other way round : the only two declarations in banking
          # whose removal made the runtimes disagree were both `identified_by`,
          # and they disagreed because removing them fell through to here.
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
                                                         identity: identity_reading(aggregate),
                                                         offered: Rendering.describe(id)))
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
