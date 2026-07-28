# Dispatcher — the door. Every command enters here, by fully-qualified verb.
#
#   dispatch("Pizzas::Pizza.Purchase", id: "pizza-1a2b", customer_name: "Chris")
#
# The sequence is fixed and entirely IR-driven — there is no handler body
# anywhere in this codebase:
#
#   1. resolve   — verb → bluebook → aggregate → command                (here)
#   2. hydrate   — load by id, or mint for a creating command   \
#   3. guard     — every `given` must hold, or refuse untouched  |
#   4. mutate    — creation attributes, then each `then_set`      > CommandInterpreter
#   5. persist   — save through the bound adapter                |     (EntityInterpreter
#   6. emit      — announce, only after the state is stored     /       one element deep)
#   7. react     — policies fire on what was announced           > PolicyInterpreter
#   8. remember  — conversations advance on the same events      > SagaInterpreter
#
# The door does step 1 and then SEQUENCES the rest. That ordering is the one
# thing it owns and the reason it is worth being a separate object: emit before
# react, always, because an event is a promise that the state behind it
# survived, and a reaction promises the same thing about the event. React
# before remember, so a policy's reaction and a saga's advance read the same
# event in a fixed order on both runtimes.
#
# Each interpreter is reachable only through here. A reaction re-enters by this
# same door rather than by a private path, so a consequence is dispatched on
# exactly the terms any caller gets.
#
# THE RE-ENTRY COUNTER LIVES HERE, with the re-entry it bounds. A policy that
# wakes a saga that dispatches again is ONE chain ; a counter per interpreter
# would count it as two shallow ones and the bound would not hold.
require_relative "errors"
require_relative "command_rules"
require_relative "command_interpreter"
require_relative "entity_interpreter"
require_relative "query_interpreter"
require_relative "policy_interpreter"
require_relative "saga_interpreter"

module Hecksagain
  module Runtime
    class Dispatcher
      # A policy whose command emits the event it waits for would react for
      # ever. Bounded rather than detected : the cycle is a modelling error,
      # and the runtime's job is to stop rather than to diagnose.
      MAX_REACTION_DEPTH = 5

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
        # The rules a command obeys whatever it acts on — held once, so the
        # record path and the element path cannot drift apart.
        rules     = CommandRules.new(registry)
        @commands = CommandInterpreter.new(registry, rules: rules)
        @entities = EntityInterpreter.new(registry, rules: rules)
        @queries  = QueryInterpreter.new(registry)
        @policies = PolicyInterpreter.new(registry, door: self)
        @sagas    = SagaInterpreter.new(registry, door: self)
      end

      # Every event emitted this session, oldest first.
      def events = @registry.event_log

      # Every policy that fired this session, and whether its command landed.
      def reactions = @registry.reaction_log

      # Every process-manager step this session — born, advanced, refused,
      # ended — oldest first.
      def sagas = @registry.saga_log
      def verbs = @registry.verbs

      def dispatch(verb, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        # `Order.OrderLine.Restock` — the three-part spelling the Entity IR
        # documented from the day it was written : an entity is addressed
        # THROUGH the parent, never around it.
        instance, announced =
          if command_name.include?(".")
            @entities.call(domain, aggregate, command_name, args)
          else
            command = aggregate.command(command_name) ||
                      raise(UnknownVerb, "#{aggregate_name} has no command #{command_name.inspect}")
            @commands.call(domain, aggregate, command, args)
          end

        # 7. REACT — a policy is a standing instruction that something else
        # should follow, so the reflex fires after the event it waits for.
        announced.each { |event| @policies.react(event, domain) }

        # 8. REMEMBER — a process manager is the conversation that outlives
        # any one command.
        announced.each { |event| @sagas.advance(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
      end

      # A question takes the same door as a command, and for the same reason :
      # one place turns a fully-qualified name into a resolved aggregate.
      def query(verb, **args)
        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.call(domain, aggregate, query_name, args)
      end

      # RE-ENTRY, for the interpreters that cause consequences. Depth rides an
      # ivar rather than an argument because the nested call goes back through
      # the PUBLIC dispatch, which takes a verb and attrs and nothing else —
      # threading it as a parameter would mean widening the door for the
      # benefit of one caller.
      def reenter(verb, **args)
        depth = @reaction_depth.to_i
        @reaction_depth = depth + 1
        dispatch(verb, **args)
      ensure
        @reaction_depth = depth
      end

      def reaction_depth_reached? = @reaction_depth.to_i >= MAX_REACTION_DEPTH
      def max_reaction_depth      = MAX_REACTION_DEPTH

      private

      # "Pizzas::Pizza.Purchase" => ["Pizzas", "Pizza", "Purchase"]
      #
      # The SHAPE of a verb is Naming's to know ; the REFUSAL is the door's,
      # because only the door knows what it was asked for.
      def parse(verb)
        Naming.split_verb(verb) ||
          raise(UnknownVerb, "#{verb.inspect} is not a fully-qualified verb (Domain::Aggregate.Command)")
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
