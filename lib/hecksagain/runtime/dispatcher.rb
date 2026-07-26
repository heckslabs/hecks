# Dispatcher — the door. Every command enters here, by fully-qualified verb.
#
#   dispatch("Pizzas::Pizza.Purchase", id: "pizza-1a2b", customer_name: "Chris")
#
# The sequence is fixed and entirely IR-driven — there is no handler body
# anywhere in this codebase:
#
#   1. resolve   — verb → bluebook → aggregate → command
#   2. hydrate   — load by id, or mint a fresh instance for a creating command
#   3. guard     — every `given` must hold, or the command is refused untouched
#   4. mutate    — creation attributes, then each `then_set`
#   5. persist   — save through the bound adapter
#   6. emit      — announce, only after the state is safely stored
#
# Emitting last is deliberate: an event is a promise that the state behind it
# survived.
require "securerandom"

module Hecksagain
  module Runtime
    class UnknownVerb < StandardError; end
    class GivenNotMet < StandardError; end
    class NotFound    < StandardError; end

    class Dispatcher
      # What a dispatch gives back: the instance as it now stands, and whatever
      # it announced.
      Result = Struct.new(:verb, :instance, :events, keyword_init: true) do
        def id    = instance.id
        def state = instance.to_h

        def to_s
          announced = events.empty? ? "no events" : events.map(&:name).join(", ")
          "#{verb} → #{instance.inspect} | #{announced}"
        end

        def inspect = "#<Result #{self}>"
      end

      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # Every event emitted this session, oldest first.
      def events = @registry.event_log
      def verbs  = @registry.verbs

      def dispatch(verb, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)
        command   = aggregate.command(command_name) ||
                    raise(UnknownVerb, "#{aggregate_name} has no command #{command_name.inspect}")

        repository = @registry.repository(domain, aggregate)
        instance   = hydrate(repository, aggregate, command, args)

        enforce_givens(instance, command, args)
        assign_creation_attributes(instance, aggregate, command, args) if command.creates?
        command.mutations.each { |mutation| apply(instance, aggregate, mutation, args) }

        repository.save(instance)
        Result.new(verb: verb, instance: instance, events: emit(command, domain, aggregate, instance, args, repository))
      end

      private

      # "Pizzas::Pizza.Purchase" => ["Pizzas", "Pizza", "Purchase"]
      def parse(verb)
        path, command = verb.to_s.split(".", 2)
        domain, aggregate = path.to_s.split("::", 2)

        unless domain && aggregate && command
          raise UnknownVerb, "#{verb.inspect} is not a fully-qualified verb (Domain::Aggregate.Command)"
        end

        [domain, aggregate, command]
      end

      def resolve_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, "no domain #{domain.inspect} loaded (verb #{verb})")
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, "#{domain} has no aggregate #{aggregate_name.inspect}")
      end

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

          instance[attr.name] = args[attr.name]
        end
      end

      def apply(instance, aggregate, mutation, args)
        case mutation.op
        when :set    then instance[mutation.target] = resolve_source(mutation.source, args)
        when :append then instance[mutation.target] = appended(instance, aggregate, mutation, args)
        end
      end

      # A Symbol naming a command attribute reads that argument ; anything else
      # is a literal.
      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
      end

      def appended(instance, aggregate, mutation, args)
        fields       = mutation.source.transform_values { |arg| args[arg] }
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
