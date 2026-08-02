require_relative "interpreting"
require_relative "command_interpreter/argument_gate"
require_relative "command_interpreter/mutation_applier"
require_relative "../rendering"
require_relative "errors"
require_relative "identity"
require_relative "instance"

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

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      def call(domain, aggregate, command, args)
        args       = step(:normalize_args) { normalize_args(domain, aggregate, command, args) }
        step(:resolve_references) { @rules.resolve_references(domain, command, args) }
        repository = @registry.repository(domain, aggregate)
        instance   = step(:hydrate) { hydrate(repository, aggregate, command, args) }

        step(:enforce_givens) { @rules.enforce_givens(instance, command, args) }
        transition = step(:admissible_transition) { @rules.admissible_transition(aggregate, command, instance) }
        step(:assign_creation_attributes) { assign_creation_attributes(instance, aggregate, command, args) } if command.creates?
        step(:apply_mutations) { command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) } }
        step(:advance_lifecycle) { instance[aggregate.lifecycle.field] = transition.target } if transition

        step(:save) { repository.save(instance) }

        [instance, step(:emit) { @rules.emit(command, domain, aggregate, instance, args, repository) }]
      end

      private

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
               raise(NotFound, "#{command.hecks_name} creates a #{aggregate.hecks_name} — pass #{identity_reading(aggregate)}:")
          # A SECOND CREATION IS NOT A FRESH ONE. Nothing here checked whether
          # the derived id already named a record, so the same creating
          # command dispatched twice with the same identity silently built a
          # SECOND `Instance` and overwrote the first at save — the tenant a
          # box was rented to, gone without a refusal. A branch and box
          # number are a small, finite set a caller can collide with by
          # mistake in a way a minted reference cannot.
          raise(AlreadyExists, "#{command.hecks_name} creates a #{aggregate.hecks_name} that already exists — " \
                                "#{identity_reading(aggregate)} #{Rendering.describe(id)}") if repository.find(id)

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
               raise(NotFound, "#{command.hecks_name} acts on an existing #{aggregate.hecks_name} — pass #{identity_reading(aggregate)}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.hecks_name} with #{identity_reading(aggregate)} #{Rendering.describe(id)}")
        end
      end

      def normalize_args(domain, aggregate, command, args)
        step(:refuse_unknown_arguments) { refuse_unknown_arguments(domain, aggregate, command, args) }
        # Unknown first, deliberately : a payload that both misspells one name and
        # omits another is more usefully told about the name that does not exist.
        step(:refuse_absent_arguments)  { refuse_absent_arguments(command, args) }

        coerce_declared_arguments(aggregate, command, args)
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
