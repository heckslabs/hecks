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
    # A value arrived in a shape the domain does not admit — a scalar where a
    # multi-field value object was declared. Loud, because the alternative is
    # storing it raw and answering nil to every dotted read of it.
    class TypeMismatch < StandardError; end

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

      # Every policy that fired this session, and whether its command landed.
      def reactions = @registry.reaction_log
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
        announced = emit(command, domain, aggregate, instance, args, repository)

        # 7. REACT — a policy is a standing instruction that something else
        # should follow, so the reflex fires after the event it waits for.
        # After emit, for the same reason emit is last : a reaction is a
        # promise the state behind it survived.
        announced.each { |event| react_to(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
      end

      private

      # The domain's reflex, finally connected. Four policies across the
      # corpus parsed, reached the IR, were agreed on byte-for-byte by both
      # parsers — and then fired nowhere, in either runtime. Parity was green
      # BECAUSE both discarded them equally : stage one cannot tell "both
      # understood it" from "both threw it away".
      #
      # EVERY reaction is recorded, delivered or not. A policy pointing at a
      # domain nobody loaded (pizzas' Notifications.Send) is a real thing to
      # know about, and swallowing it would rebuild the silence this fixes.
      def react_to(event, domain)
        # Depth rides an ivar rather than an argument because the nested call
        # goes back through the PUBLIC dispatch, which takes a verb and attrs
        # and nothing else. Threading it as a parameter would mean widening
        # the door for the benefit of one caller.
        depth = @reaction_depth.to_i

        policies_for(event, domain).each do |policy|
          @registry.reaction_log << deliver(policy, event, domain, depth)
        end
      end

      # A policy matches on the event NAME, and when its subscription is
      # qualified (`on "Order.Placed"`) on the emitting aggregate too. Both
      # helpers already existed on IR::Policy, unused — written for a
      # reaction that was never wired.
      def policies_for(event, domain)
        bluebook = @registry.bluebook(domain)
        return [] unless bluebook

        emitting = event.aggregate.to_s.split("::").last

        # DOMAIN-LEVEL ONLY. An aggregate-nested policy BUBBLES to the domain
        # at build time — the aggregate keeps a copy for its own IR, and
        # bluebook_builder says where the two agree : "the interpreter holds
        # them domain-level only". Reading both lists fired every nested
        # policy twice, which is what four reactions for two events looked
        # like before this comment was read.
        bluebook.policies.select do |policy|
          policy.event_name == event.name &&
            (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end
      end

      # THE REACTION HAS NO ARGUMENT MAPPING, and that is deliberate. Hecks's
      # policy builder carries `with` / `map` / `defaults` / `translate` ;
      # this one narrowed to on/trigger/across because, as its own comment
      # says, "a keyword that parses and then does nothing is worse than one
      # that is absent". So the event's payload is the only honest input, and
      # a reaction needing more than it carries CANNOT complete.
      #
      # That is recorded rather than raised. The triggering command already
      # succeeded and its state is saved ; a consequence that cannot be
      # delivered does not retract it. What it must not do is vanish.
      def deliver(policy, event, domain, depth)
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        return record.merge(delivered: false, reason: "reaction depth #{MAX_REACTION_DEPTH} reached") if depth >= MAX_REACTION_DEPTH

        dispatch_reaction(target, event, domain, depth)
        record.merge(delivered: true)
      rescue StandardError => error
        record.merge(delivered: false, reason: error.message)
      end

      def dispatch_reaction(target, event, domain, depth)
        @reaction_depth = depth + 1
        dispatch(target, **event.payload.transform_keys(&:to_sym))
      ensure
        @reaction_depth = depth
      end

      # A policy whose command emits the event it waits for would react for
      # ever. Bounded rather than detected : the cycle is a modelling error,
      # and the runtime's job is to stop rather than to diagnose.
      MAX_REACTION_DEPTH = 5

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
        end
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
