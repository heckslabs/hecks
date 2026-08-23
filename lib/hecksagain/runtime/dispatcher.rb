require_relative "errors"
require_relative "refusal_wording"
require_relative "caller"
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
        # `instance` is nil for a port operation dispatched by verb (below)
        # — nothing was hydrated or saved, the same reason
        # `PortOperationInterpreter#emit`'s own comment gives for sourcing
        # `id:` off the operation's reference attribute instead. `&.`, not
        # a raised error: a caller that dispatches a port verb and then
        # asks this Result for `.id`/`.state` made a category error the
        # domain itself already told it about (there is no record here),
        # not a crash-worthy one.
        def id    = instance&.id
        def state = instance&.to_h

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
      def saga_dispatches = @registry.saga_dispatch_log
      def policy_dispatches = @registry.policy_dispatch_log
      def verbs = @registry.verbs

      def dispatch(verb, saga_correlation: nil, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        instance, announced =
          if command_name.include?(".")
            head, sub = command_name.split(".", 2)
            port = aggregate.port(head)
            # A PORT OPERATION, reached by the SAME verb shape an entity
            # command already uses ("Domain::Aggregate.Head.Rest") — ports
            # are checked first, so an aggregate that ever declared both a
            # port and an entity of the same name would resolve to the
            # port; no domain in this corpus does, and `dispatch_port`'s
            # own header already named this as an open wire-spelling
            # question this resolves, not silently avoids. No `instance`
            # comes back — nothing is hydrated or saved by a port
            # operation (`PortOperationInterpreter`'s own header) — so
            # `Result#id`/`#state` are nil-safe (above) for exactly this
            # path.
            if port
              operation = port.operation(sub) ||
                          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "port_no_operation",
                                                                   port: head, operation: sub.inspect))
              [nil, @port_ops.call(domain, aggregate, operation, args)]
            else
              @entities.call(domain, aggregate, command_name, args)
            end
          else
            command = aggregate.command(command_name) ||
                      raise(UnknownVerb, RefusalWording.render("UnknownVerb", "aggregate_no_command",
                                                               aggregate: aggregate_name, command: command_name.inspect))
            @commands.call(domain, aggregate, command, args, saga_correlation)
          end

        # Correlation is SET AT CONSTRUCTION now, not merged on here —
        # it is part of the transaction, known from this method's own
        # argument before a single event exists. It used to be stamped
        # onto already-emitted events, which is what kept an event
        # mutable after it had happened.
        #
        # The ordering this note used to guard still holds, and more
        # simply: `SagaInterpreter#advance` runs on THIS domain's
        # `announced` events within this very call, and finds the
        # correlation already there because it was never absent.

        announced.each { |event| @policies.react(event, domain) }

        announced.each { |event| @sagas.advance(event, domain) }

        Result.new(verb: verb, instance: instance, events: announced)
      end

      # "IF THIS WERE DISPATCHED RIGHT NOW, WOULD IT SUCCEED" — the same
      # pipeline #dispatch itself runs (arguments coerced, givens checked,
      # mutations applied IN MEMORY, ensures checked against the settled
      # result), except `step_save`/`step_emit` never run, and neither do
      # policies or sagas afterward: nothing here is committed, so nothing
      # should react to it. Built for exactly the shape a whole-board
      # postcondition needs to be tested against (a downstream project's
      # own chess domain, checking "does this move leave my own king in
      # check" — the alternative was dispatching a real, unrelated piece's
      # own move purely to trigger the check, which then had to avoid
      # interfering with the very position being tested).
      #
      # RAISES THE SAME REFUSALS #dispatch does — a DomainRefusal
      # subclass propagates normally, so a caller checking "would this be
      # legal" writes the identical rescue clause a real dispatch already
      # needs; this returns `true` only when nothing was refused.
      #
      # NEVER A PORT VERB — `PortOperationInterpreter`'s own side effects
      # (an external gateway call, say) have no meaningful in-memory-only
      # form, so this refuses one outright rather than silently running
      # it for real, which "dry" would otherwise quietly lie about.
      def dry_run?(verb, **args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        if command_name.include?(".")
          head, = command_name.split(".", 2)
          if aggregate.port(head)
            raise WiringError,
                  "#{verb} names a port operation — dry_run has no in-memory form for one, " \
                  "only for aggregate and entity commands"
          end

          @entities.call(domain, aggregate, command_name, args, dry_run: true)
        else
          command = aggregate.command(command_name) ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "aggregate_no_command",
                                                             aggregate: aggregate_name, command: command_name.inspect))
          @commands.call(domain, aggregate, command, args, dry_run: true)
        end

        true
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

      # A reaction is the SYSTEM acting, not the caller who happened to be
      # on the stack when the triggering command ran — the ambient caller
      # is cleared for the reaction's own dispatch, so a triggering
      # caller's role can neither satisfy nor block a reaction command it
      # has nothing to do with (Runtime::Caller.without).
      def reenter(verb, saga_correlation: nil, **args)
        depth = @reaction_depth.to_i
        @reaction_depth = depth + 1
        Caller.without { dispatch(verb, saga_correlation: saga_correlation, **args) }
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
