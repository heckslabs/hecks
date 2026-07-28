# CommandInterpreter — what happens to ONE aggregate when ONE command lands.
#
# Steps 2 through 6 of the dispatch sequence, and nothing else. The door
# (Dispatcher) has already turned a verb into a domain, an aggregate and a
# command ; this reads the IR and carries them out:
#
#   2. hydrate   — load by id, or mint a fresh instance for a creating command
#   3. guard     — every `given` must hold, or the command is refused untouched
#   4. mutate    — creation attributes, then each `then_set`
#   5. persist   — save through the bound adapter
#   6. emit      — announce, only after the state is safely stored
#
# Emitting last is deliberate: an event is a promise that the state behind it
# survived.
#
# It knows nothing of policies, sagas, or verb strings. Consequences belong to
# whoever called it — this answers only "what did this command do to this
# aggregate, and what did it announce".
#
# ONE PUBLIC METHOD. The rules a command obeys whatever it acts on — guard,
# lifecycle, sourcing, arithmetic, emit — live in CommandRules, which the
# element path calls too. Publishing them from here instead would make that
# path a reuser of this one's guts rather than its peer.
#
#   CommandInterpreter.new(registry, rules: rules).call(domain, aggregate, command, args)
#   # => [instance, events]
require "securerandom"

module Hecksagain
  module Runtime
    class CommandInterpreter
      attr_reader :registry

      def initialize(registry, rules:)
        @registry = registry
        @rules    = rules
      end

      # The instance as it now stands, and whatever it announced.
      def call(domain, aggregate, command, args)
        repository = @registry.repository(domain, aggregate)
        instance   = hydrate(repository, aggregate, command, args)

        @rules.enforce_givens(instance, command, args)
        # The state machine gates BEFORE anything is written and moves AFTER
        # the mutations land — a refused Freeze touches nothing, and a legal
        # one changes state exactly once, beside the fields the command set.
        transition = @rules.admissible_transition(aggregate, command, instance)
        assign_creation_attributes(instance, aggregate, command, args) if command.creates?
        command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) }
        instance[aggregate.lifecycle.field] = transition.target if transition

        repository.save(instance)

        [instance, @rules.emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      # A creating command mints identity ; every other command loads by it.
      #
      # Three spellings address a record, in order : the natural key
      # (identified_by), the universal `id:`, and the REFERENCE KEY — the
      # snake_case of the aggregate a `reference_to` names, so `Reverse`
      # takes `transfer:` and `Suspend` takes `customer:`. Hecks locked this
      # convention long ago ; here only the first spelling ever resolved, so
      # every `transfer:`-addressed command in the corpus — the whole saga's
      # Debited/Settle/Reverse surface — refused with "pass id:", in both
      # runtimes, and 21 agreeing refusals looked like a passing suite.
      def hydrate(repository, aggregate, command, args)
        if command.creates?
          id = args[aggregate.identified_by] || mint_id(aggregate)
          Instance.new(aggregate: aggregate, id: id)
        else
          id = args[aggregate.identified_by] || args[:id] || args[reference_key(command)] ||
               raise(NotFound, "#{command.name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      # `reference_to Transfer` means the caller may say `transfer:`.
      def reference_key(command)
        target = command.references.to_s
        return nil if target.empty?

        target.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
      end

      def mint_id(aggregate)
        "#{aggregate.storage_name}-#{SecureRandom.hex(4)}"
      end

      # On creation, a command attribute sharing a name with an aggregate
      # attribute lands on it. No then_set needed for the obvious case.
      def assign_creation_attributes(instance, aggregate, command, args)
        command.attributes.each do |attr|
          next unless aggregate.attribute(attr.name)
          next unless args.key?(attr.name)

          instance[attr.name] = Value.for(aggregate, attr.name, args[attr.name])
        end
      end

      def apply(instance, aggregate, mutation, args)
        case mutation.op
        when :set
          value = @rules.resolve_source(mutation.source, args)
          instance[mutation.target] = Value.for(aggregate, mutation.target, value)
        when :append
          instance[mutation.target] = appended(instance, aggregate, mutation, args)
        when :increment, :decrement
          instance[mutation.target] = @rules.arithmetic(
            instance[mutation.target],
            @rules.resolve_source(mutation.source, args),
            mutation.target,
            @rules.sign_of(mutation.op)
          )
        end
      end

      # An appended field is either an ARGUMENT to read or a LITERAL to write —
      # the same Symbol-vs-literal rule resolve_source applies to `to:`. This
      # read every field as an argument lookup, so a literal like
      # `direction: "credit"` looked up args["credit"], found nothing, and every
      # ledger entry in the corpus carried `direction: null` — in BOTH runtimes,
      # which is why parity never said a word.
      def appended(instance, aggregate, mutation, args)
        fields       = mutation.source.transform_values { |source| source.is_a?(Symbol) ? args[source] : source }
        element_type = aggregate.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        element      = value_object ? Value.build(value_object, fields) : entity_element(aggregate, element_type, instance[mutation.target], fields)

        Array(instance[mutation.target]) + [element]
      end

      # An ENTITY element is born WITH its identity and its lifecycle state —
      # "an entity has identity that outlives its values", and until this
      # method no appended ledger entry carried the `sequence` its own
      # `identified_by` declared, so nothing could ever address one. The
      # identity defaults to its position (1-based, append order IS the
      # order it was posted) unless the append names it.
      def entity_element(aggregate, element_type, current, fields)
        entity = aggregate.entities.find { |e| e.name == element_type.to_s }
        return fields unless entity

        fields[entity.identified_by] ||= Array(current).size + 1 if entity.identified_by
        fields[entity.lifecycle.field] ||= entity.lifecycle.default if entity.lifecycle
        fields
      end
    end
  end
end
