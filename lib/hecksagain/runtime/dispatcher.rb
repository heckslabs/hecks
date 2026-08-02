require_relative "errors"
require_relative "command_rules"
require_relative "command_interpreter"
require_relative "entity_interpreter"
require_relative "query_interpreter"
require_relative "read_model_interpreter"
require_relative "policy_interpreter"
require_relative "saga_interpreter"
require_relative "../naming"

module Hecksagain
  module Runtime
    class Dispatcher
      MAX_REACTION_DEPTH = 5

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
        rules     = CommandRules.new(registry)
        @commands = CommandInterpreter.new(registry, rules: rules)
        @entities = EntityInterpreter.new(registry, rules: rules)
        @queries  = QueryInterpreter.new(registry)
        @read_models = ReadModelInterpreter.new(registry)
        @policies = PolicyInterpreter.new(registry, door: self)
        @sagas    = SagaInterpreter.new(registry, door: self)
      end

      def events = @registry.event_log

      def reactions = @registry.reaction_log

      def sagas = @registry.saga_log
      def verbs = @registry.verbs

      def dispatch(verb, saga_correlation: nil, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        instance, announced =
          if command_name.include?(".")
            @entities.call(domain, aggregate, command_name, args)
          else
            command = aggregate.command(command_name) ||
                      raise(UnknownVerb, "#{aggregate_name} has no command #{command_name.inspect}")
            @commands.call(domain, aggregate, command, args)
          end

        # STAMPED BEFORE reactions and sagas see these events, not after —
        # `SagaInterpreter#advance` runs on THIS domain's `announced` events
        # within this very call, and a step further down the same saga has to
        # find the stamp already there. See `Event#correlation`'s own comment.
        if saga_correlation
          announced.each { |event| (event.correlation ||= {}).merge!(saga_correlation) }
        end

        announced.each { |event| @policies.react(event, domain) }

        announced.each { |event| @sagas.advance(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
      end

      def query(verb, **args)
        domain, query_name = verb.to_s.split(".", 2)
        if query_name && !domain.include?("::")
          bluebook = @registry.bluebook(domain) || raise(UnknownVerb, "no domain #{domain.inspect} loaded (verb #{verb})")
          model = bluebook.read_model(query_name) || raise(UnknownVerb, "#{domain} has no read model #{query_name.inspect}")
          return @read_models.call(domain, model, args)
        end

        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.call(domain, aggregate, query_name, args)
      end

      def reenter(verb, saga_correlation: nil, **args)
        depth = @reaction_depth.to_i
        @reaction_depth = depth + 1
        dispatch(verb, saga_correlation: saga_correlation, **args)
      ensure
        @reaction_depth = depth
      end

      def reaction_depth_reached? = @reaction_depth.to_i >= MAX_REACTION_DEPTH
      def max_reaction_depth      = MAX_REACTION_DEPTH

      private

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
