require_relative "errors"
require_relative "refusal_wording"
require_relative "caller"
require_relative "invocation"
require_relative "command_rules"
require_relative "command_interpreter"
require_relative "entity_interpreter"
require_relative "query_interpreter"
require_relative "read_model_interpreter"
require_relative "policy_interpreter"
require_relative "saga_interpreter"
require_relative "outbox"
require_relative "../naming"

module Hecks
  module Runtime
    # Routes a "Domain::Aggregate.Command" verb to its interpreter, then runs the policy
    # and saga reactions its events trigger; tracks reaction depth to bound cascades.
    class Dispatcher
      MAX_REACTION_DEPTH = 5

      Result = Struct.new(:verb, :instance, :events, :execution_plan, :persistence_outcome, keyword_init: true) do
        # Reads the identity of the record the dispatch settled on.
        #
        # @return [String, nil] the record's identity; nil for a port operation (no record)
        def id    = instance&.id

        # Reads the settled record's attributes as one Hash.
        #
        # @return [Hash{Symbol => Object}, nil] the record's state; nil for a port operation
        def state = instance&.to_h

        def to_s
          announced = events.empty? ? "no events" : events.map(&:name).join(", ")
          "#{verb} → #{instance.inspect} | #{announced}"
        end

        def inspect = "#<Result #{self}>"
      end

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry every interpreter reads
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
        # One relay per registry: interpreters enqueue through it inside the save transaction.
        @registry.outbox.attach(policies: @policies, sagas: @sagas)
      end

      # Exposes the registry's outbox relay, through which this dispatcher drains reactions.
      #
      # @return [Runtime::Outbox::Relay] the registry's one relay
      def outbox = @registry.outbox

      # Exposes every event emitted through this registry, oldest first.
      #
      # @return [Array<Runtime::Event>]
      def events = @registry.event_log

      # Exposes one record per policy reaction delivered, refused or left undelivered.
      #
      # @return [Array<Hash{Symbol => Object}>]
      def reactions = @registry.reaction_log

      # Exposes one record per process-manager step: a start, an advance, a delivery, a refusal.
      #
      # @return [Array<Hash{Symbol => Object}>]
      def sagas = @registry.saga_log

      # Exposes the raw inputs each saga dispatch bound its arguments from (Ruby-only).
      #
      # @return [Array<Hash{Symbol => Object}>]
      def saga_dispatches = @registry.saga_dispatch_log

      # Exposes the raw inputs each policy trigger bound its arguments from (Ruby-only).
      #
      # @return [Array<Hash{Symbol => Object}>] entries keyed `:policy`, `:on`, `:payload`,
      #   `:with_spec` and `:args`
      def policy_dispatches = @registry.policy_dispatch_log

      # Lists every verb the loaded bluebooks declare.
      #
      # @return [Array<String>] sorted
      def verbs = @registry.verbs

      # Runs one command, entity command or port operation, then the reactions its events owe.
      #
      # @param verb [String] `"Domain::Aggregate.Command"`, `"Domain::Aggregate.Entity.Command"`
      #   or `"Domain::Aggregate.Port.Operation"`
      # @param to [String, Hash, nil] the receiver: an aggregate identity, or an entity route Hash
      #   with `:aggregate` and `:entity`/`:entities`
      # @param with [Hash, nil] the command's facts, keyed by argument name
      # @param saga_correlation [Hash, nil] stamped on emitted events when a saga leg dispatches
      # @return [Runtime::Dispatcher::Result] the instance is nil for a port operation
      # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
      # @raise [StandardError] a `Runtime::DOMAIN_REFUSALS` class when the domain refuses
      # @raise [Runtime::StaleWrite] if concurrent writers win every retry
      def dispatch(verb, to: nil, with: nil, saga_correlation: nil)
        dispatch_invocation(verb, to: to, with: with, saga_correlation: saga_correlation, flat: {})
      end

      # Dispatches a verb whose receiver and facts arrive together in one flat Hash.
      #
      # The wire form: Symbol keys `:to`, `:with` and `:saga_correlation` are lifted out as
      # the keywords of `dispatch`; every other key, including a String "to", is a fact.
      #
      # @param verb [String] the fully qualified verb, in any shape `dispatch` accepts
      # @param args [Hash] the facts plus the optional Symbol keys above; not mutated
      # @return [Runtime::Dispatcher::Result] the same result `dispatch` returns
      # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
      # @raise [StandardError] a `Runtime::DOMAIN_REFUSALS` class when the domain refuses
      def dispatch_flat(verb, args = {})
        facts = args.dup
        to = facts.delete(:to)
        with = facts.delete(:with)
        saga_correlation = facts.delete(:saga_correlation)
        dispatch_invocation(verb, to: to, with: with, saga_correlation: saga_correlation, flat: facts)
      end

      def dispatch_invocation(verb, to:, with:, saga_correlation:, flat:)
        domain, aggregate_name, command_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        instance, announced, execution_plan, persistence_outcome, outbox_rows =
          if command_name.include?(".")
            head, sub = command_name.split(".", 2)
            port = aggregate.port(head)
            # Ports are checked before entities, so a port wins a name an entity also declares.
            # No instance comes back: a port operation hydrates and saves nothing.
            if port
              operation = port.operation(sub) ||
                          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "port_no_operation",
                                                                        port: head, operation: sub))
              invocation = Invocation.from_call(verb, to: to, with: with, flat: flat,
                                                      receiver: :port, aggregate: aggregate) { operation }
              [nil, @port_ops.call(domain, aggregate, operation, invocation), nil, nil, :enqueue]
            else
              resolution = nil
              invocation = Invocation.from_call(verb, to: to, with: with, flat: flat,
                                                      receiver: :entity, entity_depth: command_name.count(".")) do
                (resolution = EntityInterpreter::Resolution.of(aggregate, command_name)).command
              end
              @entities.call(domain, aggregate, resolution, invocation)
            end
          else
            command = command_of(aggregate, aggregate_name, command_name)
            invocation = Invocation.from_call(verb, to: to, with: with, flat: flat) { command }
            @commands.call(domain, aggregate, command, invocation, saga_correlation)
          end

        # Correlation is stamped as each event is built, so emitted events are never mutated.

        react(announced, domain, aggregate, outbox_rows)

        Result.new(verb: verb, instance: instance, events: announced,
                   execution_plan: execution_plan, persistence_outcome: persistence_outcome)
      end
      private :dispatch_invocation

      # Runs the policy and saga reactions owed because `announced` committed.
      #
      # A port operation saves nothing, so its outbox rows are enqueued here (`:enqueue`);
      # nil rows mean the repository has no outbox and reactions run directly.
      def react(announced, domain, aggregate, outbox_rows)
        return if announced.empty?

        repository = @registry.repository(domain, aggregate)
        outbox_rows = outbox.enqueue(repository, announced, domain) if outbox_rows == :enqueue
        outbox.deliver(outbox_rows, announced, domain, repository)
      end
      private :react

      # Answers whether a command would succeed right now, without saving, emitting or reacting.
      #
      # Runs the dispatch pipeline in memory only; refusals raise exactly as `dispatch` raises
      # them. A port verb is refused: its side effects have no in-memory form.
      #
      # @param verb [String] the fully qualified aggregate or entity command verb
      # @param args [Hash{Symbol => Object}] the facts as flat keywords; `to` and `with` are
      #   ordinary facts here, never routing
      # @return [true] whenever nothing refused
      # @raise [Runtime::WiringError] if the verb names a port operation
      # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
      # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class the real dispatch would raise
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

          # `to:`/`with:` are not keywords here; a key named either is an ordinary fact.
          resolution = nil
          invocation = Invocation.from_call(verb, to: nil, with: nil, flat: args, receiver: :entity) do
            (resolution = EntityInterpreter::Resolution.of(aggregate, command_name)).command
          end
          @entities.call(domain, aggregate, resolution, invocation, dry_run: true)
        else
          command = command_of(aggregate, aggregate_name, command_name)
          invocation = Invocation.from_call(verb, to: nil, with: nil, flat: args) { command }
          @commands.call(domain, aggregate, command, invocation, dry_run: true)
        end

        true
      end

      # Runs one port operation named by its parts, then the reactions its events owe.
      #
      # The door for an adapter outside the bluebook; the parts are separate arguments because
      # no wire spelling for a packed port verb exists.
      #
      # @param to [String, Hash, nil] the receiver; when nil it is read from the facts
      # @param with [Hash, nil] the operation's facts, keyed by argument name
      # @param flat [Hash] the `dispatch_flat` wire form, for an adapter holding a decoded webhook
      # @return [Array<Runtime::Event>] the events the operation announced
      # @raise [Runtime::UnknownVerb] if the domain, aggregate, port or operation is undeclared
      # @raise [Runtime::TypeMismatch] if no receiving identity is found, or `to:`/`with:` is bad
      # @raise [Runtime::NotFound] if the receiving record does not exist
      def dispatch_port(domain, aggregate_name, port_name, operation_name, to: nil, with: nil, flat: {})
        aggregate = resolve_aggregate(domain, aggregate_name, "#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}")
        port = aggregate.port(port_name) ||
               raise(UnknownVerb, "#{aggregate_name} has no port #{port_name.inspect}")
        operation = port.operation(operation_name) ||
                    raise(UnknownVerb, "#{port_name} has no operation #{operation_name.inspect}")

        invocation = Invocation.from_call("#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}",
                                          to: to, with: with, flat: flat,
                                          receiver: :port, aggregate: aggregate) { operation }
        announced = @port_ops.call(domain, aggregate, operation, invocation)

        react(announced, domain, aggregate, :enqueue)

        announced
      end

      # Answers a declared query: an aggregate query, an entity query, or a read model.
      #
      # `"Domain.ReadModel"` (no `::`) is a read model; `"Domain::Aggregate.Query"` and
      # `"Domain::Aggregate.Entity.Query"` are aggregate and entity queries.
      #
      # @param verb [String, Symbol] the query's verb, in one of the three shapes above
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] one Hash per matching record or element; a read model returns a
      #   one-element Array holding a Hash of head name to projected rows
      # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
      # @raise [Runtime::NotFound] if a read model's root reference names no record
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      def query(verb, **args)
        domain, query_name = verb.to_s.split(".", 2)
        if query_name && !domain.include?("::")
          bluebook = @registry.bluebook(domain) ||
                     raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
          model = bluebook.read_model(query_name) ||
                  raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_read_model",
                                                                domain: domain, query: query_name))
          return @read_models.call(domain, model, args)
        end

        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.call(domain, aggregate, query_name, args)
      end

      # Answers an aggregate or entity query through the reference interpreter alone.
      #
      # Never answered by the bound adapter's native hook; the fuzzer's query oracle diffs it
      # against `#query`. Read models have no reference twin.
      #
      # @param verb [String] `"Domain::Aggregate.Query"` or `"Domain::Aggregate.Entity.Query"`
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] one Hash per matching record or element
      # @raise [Runtime::UnknownVerb] if the verb is malformed or names something undeclared
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      def reference_query(verb, **args)
        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.reference_call(domain, aggregate, query_name, args)
      end

      # Dispatches a reaction's command one level deeper in the cascade, as the system.
      #
      # The ambient caller is cleared (Runtime::Caller.without) so the triggering caller's role
      # neither satisfies nor blocks the reaction. Depth lives in `Thread.current`, not an ivar
      # or Mutex: the dispatcher is shared across threads and cascades re-enter on one thread.
      # The depth limit is checked by the reacting interpreter, not here.
      #
      # @param verb [String] the fully qualified verb of the reaction's target command
      # @param saga_correlation [Hash{String => Object}, nil] set when a saga leg dispatches
      # @param args [Hash{Symbol => Object}] flat facts, read as `dispatch_flat` reads them
      # @return [Runtime::Dispatcher::Result] the nested dispatch's result
      # @raise [StandardError] any `Runtime::DOMAIN_REFUSALS` class; interpreters rescue these
      def reenter(verb, saga_correlation: nil, **args)
        depth = Thread.current[:hecks_reaction_depth].to_i
        Thread.current[:hecks_reaction_depth] = depth + 1
        Caller.without { dispatch_flat(verb, args.merge(saga_correlation: saga_correlation)) }
      ensure
        Thread.current[:hecks_reaction_depth] = depth
      end

      # Answers whether the calling thread's reaction cascade is as deep as it may go.
      #
      # @return [Boolean] true once nested `reenter` calls on this thread reach the limit
      def reaction_depth_reached? = Thread.current[:hecks_reaction_depth].to_i >= MAX_REACTION_DEPTH

      # Reads the cascade limit an interpreter records when it declines to react.
      #
      # @return [Integer] `MAX_REACTION_DEPTH`
      def max_reaction_depth      = MAX_REACTION_DEPTH

      private

      def parse(verb)
        Naming.split_verb(verb) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "not_fully_qualified", verb: verb))
      end

      def command_of(aggregate, aggregate_name, command_name)
        aggregate.command(command_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "aggregate_no_command",
                                                        aggregate: aggregate_name, command: command_name))
      end

      def resolve_aggregate(domain, aggregate_name, verb)
        bluebook = @registry.bluebook(domain) ||
                   raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
        bluebook.aggregate(aggregate_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_aggregate",
                                                        domain: domain, aggregate: aggregate_name))
      end
    end
  end
end
