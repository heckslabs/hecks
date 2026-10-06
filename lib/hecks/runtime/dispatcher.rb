require_relative "errors"
require_relative "refusal_wording"
require_relative "reaction_outcome"
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
require_relative "dispatcher/result"
require_relative "dispatcher/routing"
require_relative "dispatcher/queries"
require_relative "../naming"

module Hecks
  module Runtime
    # Routes a "Domain::Aggregate.Command" verb to its interpreter, then runs the policy
    # and saga reactions its events trigger; tracks reaction depth to bound cascades.
    class Dispatcher
      include Routing
      include Queries

      MAX_REACTION_DEPTH = 5

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
        dispatch_invocation(Call.new(verb: verb, to: to, with: with, saga_correlation: saga_correlation, flat: {}))
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
        dispatch_invocation(Call.new(verb: verb, to: to, with: with, saga_correlation: saga_correlation, flat: facts))
      end

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
        call = Call.new(verb: verb, flat: args)

        if command_name.include?(".")
          dry_run_entity(call, domain, aggregate, command_name)
        else
          dry_run_aggregate(call, domain, aggregate, aggregate_name, command_name)
        end

        true
      end

      # Runs one port operation named by its parts, then the reactions its events owe.
      #
      # The door for an adapter outside the bluebook; no wire spelling packs a port verb.
      #
      # @param to [String, Hash, nil] the receiver; when nil it is read from the facts
      # @param with [Hash, nil] the operation's facts, keyed by argument name
      # @param flat [Hash] the `dispatch_flat` wire form, for an adapter holding a decoded webhook
      # @return [Array<Runtime::Event>] the events the operation announced
      # @raise [Runtime::UnknownVerb] if the domain, aggregate, port or operation is undeclared
      # @raise [Runtime::TypeMismatch] if no receiving identity is found, or `to:`/`with:` is bad
      # @raise [Runtime::NotFound] if the receiving record does not exist
      # rubocop:disable-next Metrics/ParameterLists -- the public door's parts, one argument per verb segment
      def dispatch_port(domain, aggregate_name, port_name, operation_name, to: nil, with: nil, flat: {})
        verb = "#{domain}::#{aggregate_name}.#{port_name}.#{operation_name}"
        aggregate = resolve_aggregate(domain, aggregate_name, verb)
        operation = declared_operation(aggregate, aggregate_name, port_name, operation_name)

        announced = run_port_operation(Call.new(verb: verb, to: to, with: with, flat: flat), domain, aggregate, operation)

        react(announced, domain, aggregate, :enqueue)

        announced
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

      def dispatch_invocation(call)
        @registry.collecting_reactions { |reactions| dispatch_collecting(call, reactions) }
      end

      # One dispatch, with `reactions` receiving every reaction its events cause.
      def dispatch_collecting(call, reactions)
        domain, aggregate_name, command_name = parse(call.verb)
        aggregate = resolve_aggregate(domain, aggregate_name, call.verb)
        settled = route(call, domain, aggregate, aggregate_name, command_name)

        # Correlation is stamped as each event is built, so emitted events are never mutated.

        react(settled[1], domain, aggregate, settled[4])

        result_of(call.verb, settled, reactions)
      end

      def result_of(verb, settled, reactions)
        instance, announced, execution_plan, persistence_outcome, = settled
        Result.new(verb: verb, instance: instance, events: announced,
                   execution_plan: execution_plan, persistence_outcome: persistence_outcome,
                   refused_reactions: refused_from(reactions),
                   blocking_reactions: ReactionOutcome.blocking(reactions, event_of: @registry.method(:reaction_event)),
                   reaction_defects: ReactionOutcome.defects(reactions))
      end

      # The reactions among `logged` that the domain refused, as plain facts.
      #
      # A crash in a reaction is a defect, not a refusal, and is warned where it happens.
      def refused_from(logged)
        logged.select { |entry| entry[:delivered] == false && !entry[:defect] }
              .map { |entry| entry.slice(:policy, :trigger, :reason) }
      end

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

      def declared_operation(aggregate, aggregate_name, port_name, operation_name)
        port = aggregate.port(port_name) ||
               raise(UnknownVerb, "#{aggregate_name} has no port #{port_name.inspect}")
        port.operation(operation_name) ||
          raise(UnknownVerb, "#{port_name} has no operation #{operation_name.inspect}")
      end
    end
  end
end
