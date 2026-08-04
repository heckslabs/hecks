require_relative "errors"
require_relative "refusal_wording"
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
        @commands  = CommandInterpreter.new(registry, rules: rules)
        @port_ops  = PortOperationInterpreter.new(registry, rules: rules)
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
                      raise(UnknownVerb, RefusalWording.render("UnknownVerb", "aggregate_no_command",
                                                                aggregate: aggregate_name, command: command_name.inspect))
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

      # THE DOOR AN ADAPTER OUTSIDE THE BLUEBOOK CALLS THROUGH — never the
      # domain itself. `port_name`/`operation_name` are separate arguments
      # rather than one packed verb string on purpose: there is no established
      # wire spelling for "domain, aggregate, port, operation" yet, and
      # inventing one is a bigger decision than this call needs to make.
      #
      # No adapter-to-port binding lookup happens here — that is
      # `Hecks.adapter`'s existing job (unchanged by this), and wiring "which
      # adapter may call this port" through is the next piece, not this one.
      def dispatch_port(domain, aggregate_name, port_name, operation_name, **args)
        aggregate = resolve_aggregate(domain, aggregate_name, "#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}")
        port = aggregate.port(port_name) ||
               raise(UnknownVerb, "#{aggregate_name} has no port #{port_name.inspect}")
        operation = port.operation(operation_name) ||
                    raise(UnknownVerb, "#{port_name} has no operation #{operation_name.inspect}")

        announced = @port_ops.call(domain, aggregate, operation, args)

        announced.each { |event| @policies.react(event, domain) }
        announced.each { |event| @sagas.advance(event, domain) }

        announced
      end

      def query(verb, **args)
        domain, query_name = verb.to_s.split(".", 2)
        if query_name && !domain.include?("::")
          bluebook = @registry.bluebook(domain) ||
                     raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_domain", domain: domain.inspect, verb: verb))
          model = bluebook.read_model(query_name) ||
                  raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_read_model",
                                                            domain: domain, query: query_name.inspect))
          return @read_models.call(domain, model, args)
        end

        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.call(domain, aggregate, query_name, args)
      end

      # The same ask, answered by the reference interpreter alone — never
      # the bound adapter's native hook. Read models have no reference
      # twin, so only the aggregate-query form answers here; the fuzzer's
      # query oracle diffs this against #query's answer.
      def reference_query(verb, **args)
        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.reference_call(domain, aggregate, query_name, args)
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
          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "not_fully_qualified", verb: verb.inspect))
      end

      def resolve_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_domain", domain: domain.inspect, verb: verb))
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_aggregate",
                                                    domain: domain, aggregate: aggregate_name.inspect))
      end
    end
  end
end
