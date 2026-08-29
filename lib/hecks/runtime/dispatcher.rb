require_relative "errors"
require_relative "refusal_wording"
require_relative "caller"
require_relative "routing"
require_relative "command_rules"
require_relative "command_interpreter"
require_relative "entity_interpreter"
require_relative "query_interpreter"
require_relative "read_model_interpreter"
require_relative "policy_interpreter"
require_relative "saga_interpreter"
require_relative "../naming"

module Hecks
  module Runtime
    # The runtime's single dispatch entry point for one booted registry:
    # routes a "Domain::Aggregate.Command"-shaped verb to the right
    # sub-interpreter (command, entity, port operation, query, read
    # model), then runs every policy and saga reaction the resulting
    # events trigger. Also the door reactions dispatch back through
    # (#reenter), and the one place reaction-cascade depth is tracked, to
    # keep a policy/saga loop from re-triggering itself without bound.
    class Dispatcher
      MAX_REACTION_DEPTH = 5

      Result = Struct.new(:verb, :instance, :events, :execution_plan, :persistence_outcome, keyword_init: true) do
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

      def dispatch(verb, to: nil, with: nil, saga_correlation: nil, **legacy_args)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        instance, announced, execution_plan, persistence_outcome =
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
              route, args = port_invocation(aggregate, operation, to: to, with: with, legacy: legacy_args)
              [nil, @port_ops.call(domain, aggregate, operation, args, route: route), nil, nil]
            else
              entity_depth = command_name.split(".").size - 1
              route = Routing.envelope(to, entity_depth: entity_depth)
              @entities.call(domain, aggregate, command_name, legacy_args, route: route, with: with)
            end
          else
            command = aggregate.command(command_name) ||
                      raise(UnknownVerb, RefusalWording.render("UnknownVerb", "aggregate_no_command",
                                                               aggregate: aggregate_name, command: command_name.inspect))
            args = Routing.payload(command, with: with, legacy: legacy_args)
            route = Routing.envelope(to)
            @commands.call(domain, aggregate, command, args, saga_correlation, route: route)
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

        Result.new(verb: verb, instance: instance, events: announced,
                   execution_plan: execution_plan, persistence_outcome: persistence_outcome)
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
                  "#{verb} names a port operation — dry_run? has no in-memory form for one, " \
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
      def dispatch_port(domain, aggregate_name, port_name, operation_name, to: nil, with: nil, **legacy_args)
        aggregate = resolve_aggregate(domain, aggregate_name, "#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}")
        port = aggregate.port(port_name) ||
               raise(UnknownVerb, "#{aggregate_name} has no port #{port_name.inspect}")
        operation = port.operation(operation_name) ||
                    raise(UnknownVerb, "#{port_name} has no operation #{operation_name.inspect}")

        route, args = port_invocation(aggregate, operation, to: to, with: with, legacy: legacy_args)
        announced = @port_ops.call(domain, aggregate, operation, args, route: route)

        announced.each { |event| @policies.react(event, domain) }
        announced.each { |event| @sagas.advance(event, domain) }

        announced
      end

      def port_invocation(aggregate, operation, to:, with:, legacy:)
        legacy = legacy.dup
        identity = operation.identity_attribute(aggregate.hecks_name)
        if to.nil? && identity && legacy.key?(identity.name)
          to = legacy.delete(identity.name)
        elsif to.nil? && operation.to == aggregate.hecks_name
          # `to:`-DECLARED OPERATIONS carry no Reference-typed attribute at
          # all (PortOperationBuilder#initialize's own comment on why —
          # genuine routing metadata, not an attribute), so `identity`
          # above is always nil for these; this is the second, purely
          # additive lookup they need instead. The routing value sits in
          # a PLAIN external-fact attribute, named for the owning
          # aggregate's own identified_by field — the domain author's job
          # to match, same discipline reference_to's own `as:` always
          # required. Composite identity (more than one identified_by
          # component) isn't attempted here — `.first` only, no domain in
          # the real corpus has needed more for a port operation yet.
          #
          # READ, NOT deleted — unlike the Reference-attribute branch
          # above, this is a genuine declared operation attribute (Rust's
          # own comment: "declare only external facts with attribute"),
          # not synthetic routing-only state; the operation's own
          # attributes still expect to find it in the payload a few steps
          # later (refuse_absent_arguments), and a real, live
          # AbsentArgument confirmed this the hard way before `[]`
          # replaced `delete`.
          identity_name = Array(aggregate.identified_by).first
          to = legacy[identity_name] if identity_name && legacy.key?(identity_name)
        end

        route = Routing.envelope(to)
        raise TypeMismatch, "#{operation.hecks_name} requires its receiving aggregate in to:" unless route

        [route, Routing.payload(operation, with: with, legacy: legacy)]
      end
      private :port_invocation

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
      #
      # `Thread.current[:hecks_reaction_depth]`, not a plain ivar — this
      # `Dispatcher` instance is a single object shared by every thread
      # dispatching through it (a Puma worker pool, say), so a plain ivar
      # here is exactly the known Puma-concurrency bug class: two
      # concurrent top-level dispatches on different threads would
      # increment/decrement the SAME counter, letting one thread's nested
      # reaction depth leak into another thread's unrelated dispatch. A
      # `Mutex` is not the answer either — a reaction cascade re-enters
      # `reenter` on the SAME thread (see `SagaInterpreter#advance_saga`'s
      # own comment on why a non-reentrant `Mutex` can't guard this).
      # `Thread.current`-backed, saved/restored around the call with a
      # plain local + `ensure`, is the same idiom `Runtime::Caller`
      # (`caller.rb`) already established for exactly this shape of
      # per-thread ambient state.
      def reenter(verb, saga_correlation: nil, **args)
        depth = Thread.current[:hecks_reaction_depth].to_i
        Thread.current[:hecks_reaction_depth] = depth + 1
        Caller.without { dispatch(verb, saga_correlation: saga_correlation, **args) }
      ensure
        Thread.current[:hecks_reaction_depth] = depth
      end

      def reaction_depth_reached? = Thread.current[:hecks_reaction_depth].to_i >= MAX_REACTION_DEPTH
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
