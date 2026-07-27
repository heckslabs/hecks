# Dispatcher — the door. Every command enters here, by fully-qualified verb.
#
#   dispatch("Pizzas::Pizza.Purchase", id: "pizza-1a2b", customer_name: "Chris")
#
# The sequence is fixed and entirely IR-driven — there is no handler body
# anywhere in this codebase:
#
#   1. resolve   — verb → bluebook → aggregate → command        (here)
#   2. hydrate   — load by id, or mint for a creating command   \
#   3. guard     — every `given` must hold, or refuse untouched  |
#   4. mutate    — creation attributes, then each `then_set`      > CommandInterpreter
#   5. persist   — save through the bound adapter                |
#   6. emit      — announce, only after the state is stored     /
#   7. react     — policies fire on what was announced           > PolicyInterpreter
#
# The door does step 1 and then SEQUENCES the rest. That ordering is the one
# thing it owns and the reason it is worth being a separate object: emit before
# react, always, because an event is a promise that the state behind it
# survived, and a reaction is a promise the same thing about the event.
#
# Each interpreter is reachable only through here. A reaction re-enters by this
# same door rather than by a private path, so a consequence is dispatched on
# exactly the terms any caller gets.
require_relative "errors"
require_relative "command_interpreter"
require_relative "policy_interpreter"

module Hecksagain
  module Runtime
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
        @commands = CommandInterpreter.new(registry)
        @policies = PolicyInterpreter.new(registry, door: self)
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

        instance, announced = @commands.call(domain, aggregate, command, args)

        # 7. REACT — a policy is a standing instruction that something else
        # should follow, so the reflex fires after the event it waits for.
        announced.each { |event| @policies.react(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
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
    end
  end
end
