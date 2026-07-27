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
#   CommandInterpreter.new(registry).call(domain, aggregate, command, args)
#   # => [instance, events]
require "securerandom"

module Hecksagain
  module Runtime
    class CommandInterpreter
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # The instance as it now stands, and whatever it announced.
      def call(domain, aggregate, command, args)
        repository = @registry.repository(domain, aggregate)
        instance   = hydrate(repository, aggregate, command, args)

        enforce_givens(instance, command, args)
        assign_creation_attributes(instance, aggregate, command, args) if command.creates?
        command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) }

        repository.save(instance)

        [instance, emit(command, domain, aggregate, instance, args, repository)]
      end

      private

      # A creating command mints identity ; every other command loads by it.
      def hydrate(repository, aggregate, command, args)
        if command.creates?
          id = args[aggregate.identified_by] || mint_id(aggregate)
          Instance.new(aggregate: aggregate, id: id)
        else
          id = args[aggregate.identified_by] ||
               raise(NotFound, "#{command.name} acts on an existing #{aggregate.name} — pass #{aggregate.identified_by}:")
          repository.find(id) || raise(NotFound, "no #{aggregate.name} with #{aggregate.identified_by} #{id.inspect}")
        end
      end

      def mint_id(aggregate)
        "#{aggregate.storage_name}-#{SecureRandom.hex(4)}"
      end

      # All givens must hold. A refused command leaves the instance untouched
      # because nothing has been written yet.
      def enforce_givens(instance, command, args)
        command.givens.each do |given|
          next if Bluebook::Expression::Evaluator.call(given.canonical, instance, args)

          raise GivenNotMet, "#{command.name} refused — #{given.description}"
        end
      end

      # On creation, a command attribute sharing a name with an aggregate
      # attribute lands on it. No then_set needed for the obvious case.
      def assign_creation_attributes(instance, aggregate, command, args)
        command.attributes.each do |attr|
          next unless aggregate.attribute(attr.name)
          next unless args.key?(attr.name)

          instance[attr.name] = coerce(aggregate, attr.name, args[attr.name])
        end
      end

      def apply(instance, aggregate, mutation, args)
        case mutation.op
        when :set
          value = resolve_source(mutation.source, args)
          instance[mutation.target] = coerce(aggregate, mutation.target, value)
        when :append
          instance[mutation.target] = appended(instance, aggregate, mutation, args)
        when :increment
          instance[mutation.target] = arithmetic(instance, mutation, args, 1)
        when :decrement
          instance[mutation.target] = arithmetic(instance, mutation, args, -1)
        end
      end

      # Integer cents or nothing. Money is the reason these ops exist, and
      # IEEE 754 has no place in a ledger — so a non-Integer amount is refused
      # LOUDLY rather than coerced. (Hecks's runtime falls back to ±1 when the
      # amount will not read as a number ; a balance moving by one cent because
      # the caller sent "lots" is exactly the silent wrongness this refuses.)
      def arithmetic(instance, mutation, args, sign)
        amount  = resolve_source(mutation.source, args)
        current = instance[mutation.target] || 0
        op      = sign.positive? ? "increment" : "decrement"

        unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer, got #{amount.inspect}"
        end
        unless current.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{mutation.target} needs an Integer #{mutation.target}, got #{current.inspect}"
        end

        current + (sign * amount)
      end

      # A VALUE-OBJECT-TYPED FIELD IS CONSTRUCTED, NOT STORED RAW.
      #
      # Value.build was only ever reached from the append path, so a scalar
      # attribute declared as a value object was assigned whatever arrived
      # and never validated. `amount: 2500` on an attribute typed Money sat
      # there as an Integer, and `amount.cents` — a dotted read into what the
      # domain says is a Money — walked into a non-Hash and answered nil.
      # Both runtimes did it, so parity was green over a value object that
      # never existed and an invariant that never fired.
      #
      # A SINGLE-ATTRIBUTE value object accepts a bare scalar, because
      # `kind: "current"` is unambiguous — there is exactly one field it
      # could mean, and making an author write `{ name: "current" }` buys
      # nothing. Anything richer must arrive as its fields, because guessing
      # which one of several a scalar meant is how a currency ends up in a
      # cents column.
      def coerce(aggregate, name, value)
        value_object = value_object_for(aggregate, name)
        return value unless value_object
        return value if value.nil?

        Value.build(value_object, fields_for(value_object, name, value))
      end

      # The value object a SCALAR attribute is declared as, or nil. A list
      # attribute is built element by element in `appended`, not here.
      def value_object_for(aggregate, name)
        attribute = aggregate.attribute(name)
        return nil unless attribute&.scalar?

        aggregate.value_object(attribute.type)
      end

      def fields_for(value_object, name, value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)

        only = value_object.attributes
        if only.size == 1
          return { only.first.name => value }
        end

        raise TypeMismatch,
              "#{name} is a #{value_object.name}, which has " \
              "#{only.map { |a| a.name }.join(', ')} — pass those fields, not " \
              "#{value.inspect}. A scalar can only stand in for a value " \
              "object with exactly one field."
      end

      # A Symbol naming a command attribute reads that argument ; anything else
      # is a literal.
      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
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
        element      = value_object ? Value.build(value_object, fields) : fields

        Array(instance[mutation.target]) + [element]
      end

      def emit(command, domain, aggregate, instance, args, repository)
        command.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{domain}::#{aggregate.name}",
            id:          instance.id,
            payload:     args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event
          repository.record_event(event) if repository.respond_to?(:record_event)
          event
        end
      end
    end
  end
end
