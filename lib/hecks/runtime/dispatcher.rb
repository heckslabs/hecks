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
        # Reads the identity of the record the dispatch settled on.
        #
        # `instance` is nil for a port operation dispatched by verb (below)
        # — nothing was hydrated or saved, the same reason
        # `PortOperationInterpreter#emit`'s own comment gives for sourcing
        # `id:` off the operation's reference attribute instead. `&.`, not
        # a raised error: a caller that dispatches a port verb and then
        # asks this Result for `.id`/`.state` made a category error the
        # domain itself already told it about (there is no record here),
        # not a crash-worthy one.
        #
        # @return [String, nil] the record's identity; nil for a port operation, which
        #   hydrates no record
        def id    = instance&.id

        # Reads the settled record's attributes as one Hash, for the same nil-safe reason as `id`.
        #
        # @return [Hash{Symbol => Object}, nil] the record's state with `:id` merged in
        #   last; nil for a port operation, which hydrates no record
        def state = instance&.to_h

        def to_s
          announced = events.empty? ? "no events" : events.map(&:name).join(", ")
          "#{verb} → #{instance.inspect} | #{announced}"
        end

        def inspect = "#<Result #{self}>"
      end

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry every interpreter reads; its
      #   outbox is attached to this dispatcher's policy and saga interpreters
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
        # The relay is the registry's, not this dispatcher's — the
        # interpreters enqueue through `@registry.outbox` from inside
        # the save transaction, and this dispatcher drains through the
        # same object, so there is exactly one relay per registry no
        # matter how many dispatchers front it. What it borrows from
        # here is the pair of interpreters a consumer runs through.
        @registry.outbox.attach(policies: @policies, sagas: @sagas)
      end

      # Exposes the registry's outbox relay, the object this dispatcher drains reactions through.
      #
      # `runtime.outbox.rows`, `.rows(status: "claimed")`, `.redrive!`,
      # `.log` — see `Runtime::Outbox`.
      #
      # @return [Runtime::Outbox::Relay] the registry's one relay, shared by every dispatcher
      #   fronting that registry
      def outbox = @registry.outbox

      # Exposes every event emitted through this registry since boot or the last reset.
      #
      # @return [Array<Runtime::Event>] the registry's live event log, oldest first
      def events = @registry.event_log

      # Exposes one record per policy reaction that was delivered, refused or left undelivered.
      #
      # @return [Array<Hash{Symbol => Object}>] the registry's live reaction log, oldest first
      def reactions = @registry.reaction_log

      # Exposes one record per process-manager step: a start, an advance, a delivery, a refusal.
      #
      # @return [Array<Hash{Symbol => Object}>] the registry's live saga log, oldest first
      def sagas = @registry.saga_log

      # Exposes the raw inputs each saga dispatch bound its arguments from, a Ruby-only log.
      #
      # @return [Array<Hash{Symbol => Object}>] the registry's live saga dispatch log, oldest first
      def saga_dispatches = @registry.saga_dispatch_log

      # Exposes the raw inputs each policy trigger bound its arguments from, a Ruby-only log.
      #
      # @return [Array<Hash{Symbol => Object}>] the registry's live policy dispatch log, with
      #   keys `:policy`, `:on`, `:payload`, `:with_spec` and `:args`
      def policy_dispatches = @registry.policy_dispatch_log

      # Lists every verb the loaded bluebooks declare.
      #
      # @return [Array<String>] the verbs of every loaded bluebook, sorted
      def verbs = @registry.verbs

      # Runs one command, entity command or port operation, then every policy and saga reaction
      # its events are owed.
      #
      # **The receiver in `to:`, the facts in `with:`, and nothing else.**
      # Loose keyword facts — `dispatch(verb, amount: 5)`, one bag holding
      # both the route and the payload — were deprecated in 1.3.x and are
      # gone: Ruby now refuses them itself, by name ("unknown keyword:
      # :amount"). Code holding a bag of DATA rather than written keywords
      # calls `dispatch_flat` below; that door is not going anywhere.
      #
      # @param verb [String] the fully qualified verb: `"Domain::Aggregate.Command"`,
      #   `"Domain::Aggregate.Entity.Command"` or `"Domain::Aggregate.Port.Operation"`
      # @param to [String, Hash, nil] the receiver: an aggregate identity, or an entity route
      #   Hash with `:aggregate` and one of `:entity`/`:entities`; nil when the facts carry
      #   the identity themselves
      # @param with [Hash, nil] the command's facts, keyed by argument name (String or Symbol)
      # @param saga_correlation [Hash, nil] correlation head => value, stamped on every
      #   emitted event when a saga leg causes this dispatch; nil otherwise
      # @return [Runtime::Dispatcher::Result] the verb, settled instance (nil for a port
      #   operation), emitted events, execution plan and persistence outcome
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a domain,
      #   aggregate, command, entity or port operation that is not declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain refuses
      #   the call (`GivenNotMet`, `TypeMismatch`, `Unauthorized`, `NotFound`, …)
      # @raise [Runtime::StaleWrite] if concurrent writers beat this one through every retry
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def dispatch(verb, to: nil, with: nil, saga_correlation: nil)
        dispatch_invocation(verb, to: to, with: with, saga_correlation: saga_correlation, flat: {})
      end

      # Dispatches a verb whose receiver and facts arrive together in one flat Hash.
      #
      # **The flat-facts wire form** — one Hash, not keywords: the shape
      # `spec/corpus/*.json` steps, the Rust kernel's `cli.rs` contract, a
      # reaction without a `with:` projection, and the self-hosted
      # meta-domain all carry, where the receiver's identity is one of the
      # keys because that is how the wire spells it. Routes exactly as the
      # removed keyword door did: a Symbol `:to`, `:with` or
      # `:saga_correlation` key is lifted out as that keyword, everything
      # else is a fact (so a String "to" key stays a fact, as it did).
      # Framework code that replays data calls this; application code
      # calls `dispatch(verb, to:, with:)`.
      #
      # @param verb [String] the fully qualified verb, in any shape `dispatch` accepts
      # @param args [Hash] the facts, plus optional Symbol keys `:to`, `:with` and
      #   `:saga_correlation`, read as `dispatch`'s keywords of the same names; not mutated
      # @return [Runtime::Dispatcher::Result] the same result `dispatch` returns
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a domain,
      #   aggregate, command, entity or port operation that is not declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the domain refuses
      #   the call
      # @raise [Runtime::StaleWrite] if concurrent writers beat this one through every retry
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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
            # A port operation, reached by the same verb shape an entity
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

        # Correlation is set when each event is constructed, not merged on
        # here — it is part of the transaction, known from this method's
        # own argument before a single event exists. Stamping it onto
        # already-emitted events would keep an event mutable after it had
        # happened.
        #
        # The ordering that depends on it holds for the same reason:
        # `SagaInterpreter#advance` runs on this domain's `announced`
        # events within this very call, and finds the correlation already
        # there because it was never absent.

        react(announced, domain, aggregate, outbox_rows)

        Result.new(verb: verb, instance: instance, events: announced,
                   execution_plan: execution_plan, persistence_outcome: persistence_outcome)
      end

      # **The one body both doors run** — `dispatch` (keywords) and
      # `dispatch_flat` (one Hash) differ only in how the call's parts are
      # spelled, never in what happens next.
      private :dispatch_invocation

      # **Everything owed because `announced` committed** — policies first,
      # then sagas, the order this method always ran them in. The
      # command/entity interpreters hand back the outbox rows they
      # enqueued inside the save transaction (`Interpreting#
      # run_dispatch_order`); a port operation saves nothing, so its
      # rows are enqueued here, after the fact (`:enqueue`) — durable
      # still, just not transactional with anything, because there is
      # nothing for them to be transactional with. `nil` rows mean the
      # repository has no outbox: react directly, exactly as before.
      def react(announced, domain, aggregate, outbox_rows)
        return if announced.empty?

        repository = @registry.repository(domain, aggregate)
        outbox_rows = outbox.enqueue(repository, announced, domain) if outbox_rows == :enqueue
        outbox.deliver(outbox_rows, announced, domain, repository)
      end
      private :react

      # Answers whether a command would succeed right now, without saving, emitting or reacting.
      #
      # "If this were dispatched right now, would it succeed" — the same
      # pipeline #dispatch itself runs (arguments coerced, givens checked,
      # mutations applied in memory, ensures checked against the settled
      # result), except `step_save`/`step_emit` never run, and neither do
      # policies or sagas afterward: nothing here is committed, so nothing
      # should react to it. Built for exactly the shape a whole-board
      # postcondition needs to be tested against (a downstream project's
      # own chess domain, checking "does this move leave my own king in
      # check" — the alternative was dispatching a real, unrelated piece's
      # own move purely to trigger the check, which then had to avoid
      # interfering with the very position being tested).
      #
      # Raises the same refusals #dispatch does — a DomainRefusal
      # subclass propagates normally, so a caller checking "would this be
      # legal" writes the identical rescue clause a real dispatch already
      # needs; this returns `true` only when nothing was refused.
      #
      # **Never a port verb** — `PortOperationInterpreter`'s own side effects
      # (an external gateway call, say) have no meaningful in-memory-only
      # form, so this refuses one outright rather than silently running
      # it for real, which "dry" would otherwise quietly lie about.
      #
      # @param verb [String] the fully qualified aggregate or entity command verb
      # @param args [Hash{Symbol => Object}] the command's facts as flat keywords; a key named
      #   `to` or `with` is an ordinary fact here, never routing (BUG#131)
      # @return [true] whenever nothing refused; a refusal is raised, never returned as false
      # @raise [Runtime::WiringError] if the verb names a port operation, or the aggregate's
      #   repository cannot be resolved
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a domain,
      #   aggregate, command or entity that is not declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` that the real dispatch
      #   would raise
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

          # `to:`/`with:` are not keywords of this method — a key named
          # either is an ordinary fact here (BUG#131), so both go in as nil.
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

      # Runs one port operation named by its parts, then the reactions its events are owed.
      #
      # The door an adapter outside the bluebook calls through — never the
      # domain itself. `port_name`/`operation_name` are separate arguments
      # rather than one packed verb string on purpose: there is no established
      # wire spelling for "domain, aggregate, port, operation" yet, and
      # inventing one is a bigger decision than this call needs to make.
      #
      # No adapter-to-port binding lookup happens here — that is
      # `Hecks.adapter`'s existing job (unchanged by this), and wiring "which
      # adapter may call this port" through is the next piece, not this one.
      #
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate_name [String, Symbol] name of the aggregate that declares the port
      # @param port_name [String] name of the port, as the aggregate declares it
      # @param operation_name [String] name of the operation on that port
      # @param to [String, Hash, nil] the receiving aggregate's identity; when nil it is read
      #   from the facts, by the operation's reference or identity attribute
      # @param with [Hash, nil] the operation's facts, keyed by argument name
      # @param flat [Hash] the wire form `dispatch_flat` takes, for the driving adapter
      #   holding a decoded webhook rather than written keywords; it is where the operation's
      #   own reference attribute is read from and lifted into `to:` when `to:` is nil
      # @return [Array<Runtime::Event>] the events the operation announced: one per declared
      #   `emits` for an inbound operation, the one answering or refusing event for an
      #   outbound one
      # @raise [Runtime::UnknownVerb] if the domain, aggregate, port or operation is not declared
      # @raise [Runtime::TypeMismatch] if no receiving identity can be found, or `to:`/`with:`
      #   is malformed
      # @raise [Runtime::NotFound] if the receiving aggregate record does not exist
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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
      # The verb's shape picks the interpreter. `"Domain.ReadModel"` — no `::` before the
      # dot — is a read model; `"Domain::Aggregate.Query"` is an aggregate query, and
      # `"Domain::Aggregate.Entity.Query"` an entity query.
      #
      # @param verb [String, Symbol] the query's verb, in one of the three shapes above
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] for an aggregate query, one deep-frozen Hash per matching record,
      #   its state with `:id` merged in last; for an entity query, one Hash per matching
      #   element with the parent's reference key merged in first; for a read model, a
      #   one-element Array holding a Hash of head name to projected rows
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a domain,
      #   aggregate, entity, query or read model that is not declared
      # @raise [Runtime::NotFound] if a read model's root reference names no record
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      # @raise [KeyError] if a rooted read model is asked without its reference argument
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
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
      # The same ask as `#query`, never answered by the bound adapter's
      # native hook. Read models have no reference twin, so only the
      # `"Domain::Aggregate.Query"` forms answer here; the fuzzer's
      # query oracle diffs this against `#query`'s answer.
      #
      # @param verb [String] the fully qualified query verb, `"Domain::Aggregate.Query"` or
      #   `"Domain::Aggregate.Entity.Query"`
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] one Hash per matching record, its state with `:id` merged in
      #   last; for an entity query, one Hash per matching element
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a domain,
      #   aggregate, entity or query that is not declared
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def reference_query(verb, **args)
        domain, aggregate_name, query_name = parse(verb)
        aggregate = resolve_aggregate(domain, aggregate_name, verb)

        @queries.reference_call(domain, aggregate, query_name, args)
      end

      # Dispatches a reaction's command one level deeper in the cascade, as the system rather
      # than as the triggering caller.
      #
      # A reaction is the system acting, not the caller who happened to be
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
      # increment/decrement the same counter, letting one thread's nested
      # reaction depth leak into another thread's unrelated dispatch. A
      # `Mutex` is not the answer either — a reaction cascade re-enters
      # `reenter` on the same thread (see `SagaInterpreter#advance_saga`'s
      # own comment on why a non-reentrant `Mutex` can't guard this).
      # `Thread.current`-backed, saved/restored around the call with a
      # plain local + `ensure`, is the same idiom `Runtime::Caller`
      # (`caller.rb`) already established for exactly this shape of
      # per-thread ambient state.
      #
      # The depth is not checked here: a reacting interpreter asks
      # `reaction_depth_reached?` first and records an undelivered reaction
      # instead of calling this.
      #
      # @param verb [String] the fully qualified verb of the reaction's target command
      # @param saga_correlation [Hash{String => Object}, nil] correlation head => value when a
      #   saga leg dispatches; nil for a policy
      # @param args [Hash{Symbol => Object}] the flat facts, read exactly as `dispatch_flat`
      #   reads them, so `:to` and `:with` keys route rather than count as facts
      # @return [Runtime::Dispatcher::Result] the result of the nested dispatch
      # @raise [Runtime::UnknownVerb] if the verb names nothing declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when the target
      #   refuses; the policy and saga interpreters rescue these as recorded outcomes
      def reenter(verb, saga_correlation: nil, **args)
        depth = Thread.current[:hecks_reaction_depth].to_i
        Thread.current[:hecks_reaction_depth] = depth + 1
        Caller.without { dispatch_flat(verb, args.merge(saga_correlation: saga_correlation)) }
      ensure
        Thread.current[:hecks_reaction_depth] = depth
      end

      # Answers whether the calling thread's reaction cascade is as deep as it may go.
      #
      # @return [Boolean] true once this thread's nested `reenter` calls number
      #   `MAX_REACTION_DEPTH` or more; other threads' cascades are not counted
      def reaction_depth_reached? = Thread.current[:hecks_reaction_depth].to_i >= MAX_REACTION_DEPTH

      # Reads the cascade limit, for the reason an interpreter records when it declines to react.
      #
      # @return [Integer] `MAX_REACTION_DEPTH`, the number of nested reactions allowed
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
