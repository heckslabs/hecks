require_relative "dispatcher"
require_relative "instance"
require_relative "event"
require_relative "errors"
require_relative "../naming"
require_relative "../adapters/driven/lambda/client"
require_relative "../ports/persistence/binding_policy"
require_relative "../ports/persistence/remote_runtime"

module Hecks
  module Runtime
    # **The write-side half of lambda routing** — `Runtime::Loader.boot`
    # constructs this instead of `Dispatcher` when the booted domain's
    # own `.world` declares Lambda routing (see loader.rb's own
    # `dispatcher_class_for`). Matches `Dispatcher`'s public shape
    # closely enough that everything built on top of a dispatcher —
    # `Handle`, `AggregateDoor`, `Facade::Surface` — needs no changes
    # at all: `Handle#run`'s entire contract is
    # `@dispatcher.dispatch("#{fqn}.#{command}", to: @id, with: args).instance.state`,
    # and both classes answer that identically.
    #
    # **Reads delegate, writes don't**. `query`/`reference_query` hand off
    # to a real `Dispatcher` built over the same registry — since that
    # registry's own repositories are already Lambda-backed
    # (`Adapters::Lambda`, `persisted_by("Lambda")`, Phase 2's other
    # half), the inherited query machinery (`QueryInterpreter`,
    # `Ports::Query::InMemory.execute`) works completely unchanged, no
    # query logic duplicated here. `dispatch` can't delegate the same
    # way: command validation (givens, constraints) has to actually
    # run in Rust for a Lambda-routed domain, not get pre-checked here
    # against incomplete local state and then merely persisted.
    class RemoteDispatcher
      Result = Struct.new(:verb, :instance, :events, keyword_init: true) do
        # Reads the identity of the record the dispatch settled on.
        #
        # @return [String] the settled record's identity
        def id    = instance.id

        # Reads the settled record's attributes as one Hash.
        #
        # @return [Hash{Symbol => Object}] the settled record's attributes, `:id` merged
        #   in last
        def state = instance.to_h
      end

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry this dispatcher fronts;
      #   read-side calls (`query`/`reference_query`) delegate to a local `Dispatcher`
      #   built over the same registry
      # @param region [String] the AWS region the routed Lambda function lives in
      # @param function [String, nil] the `.world`'s own `dispatched_by("Lambda")`
      #   function name, when the deployment stack is not named `hecks-<domain>`; nil
      #   resolves the function name from `ENV["DOMAIN_NAME"]` or `registry.root`
      def initialize(registry, region: "us-east-1", function: nil)
        @registry = registry
        # `File.basename(registry.root)`, not `bluebooks.keys.first` —
        # matches `Adapters::Lambda`'s own function-name resolution
        # exactly (see its own comment on why: one merged Lambda per
        # deploy, not one per attached chapter, and `root` is the one
        # signal every bluebook in this registry shares regardless of
        # which one attached it) — including that same adapter's own
        # `ENV["DOMAIN_NAME"]`-first fix: `root` is always `/var/task`
        # inside a deployed Lambda, giving "task" instead of the real
        # domain name (a real, live AccessDeniedException on
        # "hecks-task" caught this).
        # `function:` — the `.world`'s own `dispatched_by("Lambda")`
        # naming of which function this is, for a deployment whose stack
        # name isn't `hecks-<domain>` (Client's own comment has the real
        # case). Absent, the resolution above is unchanged.
        @client = Adapters::Lambda::Client.new(domain: ENV["DOMAIN_NAME"] || File.basename(registry.root),
                                               region: region, function: function)
        # Read-side delegate only (see class comment) — never dispatched
        # through; a real Dispatcher's own `query`/`reference_query`
        # already resolve generically via `registry.repository(...)`,
        # so building one here reuses that instead of duplicating it.
        @local = Dispatcher.new(registry)
      end

      # Dispatches a command by verb, routing to the local `Dispatcher` or the
      # remote Lambda depending on the aggregate's bound adapter.
      #
      # Same shape as `Dispatcher#dispatch_flat` — everything but
      # `saga_correlation:` is forwarded through unread, `to:`/`with:`
      # included, and lifted out downstream by whichever path actually
      # dispatches (`@local.dispatch_flat` locally, the flat wire form
      # remotely). Not the strict `to:`/`with:`-only door `Dispatcher#
      # dispatch` is — see that class's own comment for why this file
      # never had one.
      #
      # @param verb [String] the fully qualified verb, `"Domain::Aggregate.Command"`
      #   or `"Domain::Aggregate.Entity.Command"`
      # @param saga_correlation [Hash, nil] correlation head => value, stamped on every
      #   emitted event when a saga leg causes this dispatch; nil otherwise
      # @param args [Hash] the facts, plus optional `:to`/`:with` keys, read the same
      #   way `dispatch_flat` reads them
      # @return [RemoteDispatcher::Result] the verb, settled instance and emitted events
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a
      #   domain or aggregate that is not declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when a
      #   locally-routed aggregate refuses the call
      # @raise [Runtime::StaleWrite] if concurrent local writers beat this one through
      #   every retry, for a locally-routed aggregate
      # @raise [Runtime::WiringError] if the aggregate's adapter or repository cannot be
      #   resolved, or the remote call is accepted but reports no mutation for it
      # @raise [Runtime::RemoteRefusal] if the routed Lambda refuses the call
      def dispatch(verb, saga_correlation: nil, **args)
        dispatch_flat(verb, args.merge(saga_correlation: saga_correlation))
      end

      # Routes a dispatch to the local `Dispatcher` when the aggregate's bound
      # adapter is not remote-backed (`Ports::Persistence::RemoteRuntime`),
      # otherwise dispatches through the routed Lambda. Same flat-facts wire
      # form as `Dispatcher#dispatch_flat`.
      #
      # @param verb [String] the fully qualified verb, in any shape `dispatch` accepts
      # @param args [Hash] the facts, plus optional Symbol keys `:to`, `:with` and
      #   `:saga_correlation`, read as `dispatch`'s keywords of the same names; not mutated
      # @return [RemoteDispatcher::Result] the verb, settled instance and emitted events
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a
      #   domain or aggregate that is not declared
      # @raise [StandardError] any class in `Runtime::DOMAIN_REFUSALS` when a
      #   locally-routed aggregate refuses the call
      # @raise [Runtime::StaleWrite] if concurrent local writers beat this one through
      #   every retry, for a locally-routed aggregate
      # @raise [Runtime::WiringError] if the aggregate's adapter or repository cannot be
      #   resolved, or the remote call is accepted but reports no mutation for it
      # @raise [Runtime::RemoteRefusal] if the routed Lambda refuses the call
      def dispatch_flat(verb, args = {})
        args = args.dup
        saga_correlation = args.delete(:saga_correlation)
        domain, aggregate_name, = Naming.split_verb(verb) ||
                                  raise(UnknownVerb,
                                        RefusalWording.render_site("UnknownVerb", "not_fully_qualified", verb: verb))
        aggregate = @registry.bluebook(domain)&.aggregate(aggregate_name) ||
                    raise(UnknownVerb,
                          RefusalWording.render_site("UnknownVerb", "no_aggregate", domain: domain, aggregate: aggregate_name))

        # Not every aggregate in a lambda-routed domain is itself
        # lambda-bound — Member's real name->email rekey carries a
        # `compute` rule (era_check.rb's own `check_compute_rules!`),
        # which can only ever run against Postgres, permanently. Its
        # own `.hecksagon` bind stays "Postgres" even when
        # `dispatched_by("Lambda")` is on for everything else — checked
        # here by real capability (`Ports::Persistence::RemoteRuntime`,
        # §1), not by comparing the adapter's own name to the string
        # "Lambda" — a bind resolves to whatever adapter class actually
        # backs it, and only a class shaped like "the real interpreter
        # lives behind a call boundary" forwards here; anything else
        # (Postgres, Memory, any future local adapter) falls through to
        # the real local Dispatcher instead of being forwarded to a
        # Lambda that has no way to represent its lineage history at
        # all.
        adapter_name = Ports::Persistence::BindingPolicy.resolve(@registry, domain, aggregate).adapter
        unless @registry.adapter_class(adapter_name) <= Ports::Persistence::RemoteRuntime
          return @local.dispatch_flat(verb, args.merge(saga_correlation: saga_correlation))
        end

        response = @client.dispatch(verb, args)

        refusal = response.fetch("refusals", []).find { |r| r["verb"] == verb }
        raise RemoteRefusal, "#{verb} refused: #{refusal['error']}" if refusal

        # This step's own mutations — `mutations` is one entry per
        # replayed step (rust/host's rehydrate-and-replay design,
        # Phase 1), so `.last` is exactly the step just dispatched.
        # Matched by fully-qualified aggregate name, not just "the
        # first mutation" — a command whose reaction also mutates a
        # different aggregate (a policy, a saga leg) puts more than
        # one mutation in the same step, and the direct effect of
        # this verb is the one this dispatch's own caller expects
        # `.instance` to be.
        fqn = "#{domain}::#{aggregate.hecks_name}"
        mutation = response.fetch("mutations", []).last&.find { |m| m["aggregate"] == fqn } ||
                   raise(WiringError,
                         "#{verb} was accepted but rust/host reported no mutation for #{fqn} — response: #{response.inspect}")

        instance = Instance.new(aggregate: aggregate, id: mutation["id"],
                                state: JSON.parse(JSON.generate(mutation["state"]), symbolize_names: true))

        Result.new(verb: verb, instance: instance, events: step_events(response))
      end

      # Delegates to the local `Dispatcher` built over the same registry — see the
      # class comment on why reads, unlike writes, need no remote-specific logic.
      #
      # @param verb [String, Symbol] the query's verb, in one of `Dispatcher#query`'s
      #   three shapes
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] see `Dispatcher#query`'s own return
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a
      #   domain, aggregate, entity, query or read model that is not declared
      # @raise [Runtime::NotFound] if a read model's root reference names no record
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      # @raise [KeyError] if a rooted read model is asked without its reference argument
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def query(verb, **args)           = @local.query(verb, **args)

      # Delegates to the local `Dispatcher` built over the same registry — see the
      # class comment on why reads, unlike writes, need no remote-specific logic.
      #
      # @param verb [String] the fully qualified query verb, `"Domain::Aggregate.Query"`
      #   or `"Domain::Aggregate.Entity.Query"`
      # @param args [Hash{Symbol => Object}] the query's declared arguments
      # @return [Array<Hash>] one Hash per matching record, its state with `:id` merged
      #   in last; for an entity query, one Hash per matching element
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified, or names a
      #   domain, aggregate, entity or query that is not declared
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its declared type
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def reference_query(verb, **args) = @local.reference_query(verb, **args)

      # Fetches the full domain's event history, on every call — `{"read":
      # true}` replays the whole journal (Phase 1's `dispatch::read`),
      # so its own `events` array already is the complete log, the
      # same thing `@registry.event_log` would answer for a local
      # dispatch. Not cached: `AggregateDoor.events`/`Handle#events`
      # are not called in this codebase's own hot paths today: if that
      # changes, caching belongs here, not in every caller.
      #
      # @return [Array<Runtime::Event>] every event in the routed Lambda's domain
      #   journal, oldest first, with `occurred_at` always nil (the kernel is
      #   timestamp-free by design)
      def events
        @client.read.fetch("events", []).map { |e| build_event(e) }
      end

      private

      def step_events(response)
        response.fetch("events", []).map { |e| build_event(e) }
      end

      # Rust's own event JSON (kernel/cli.rs's `event_to_json`) carries
      # `name`/`aggregate`/`id`/`payload` only — no `occurred_at`
      # (nothing in the kernel tracks wall-clock time; every
      # replay is deterministic and timestamp-free by design). `nil`
      # here, not a synthesized `Time.now` that would silently lie
      # about when something actually happened.
      def build_event(json)
        Event.new(name: json["name"], aggregate: json["aggregate"], id: json["id"],
                  payload: JSON.parse(JSON.generate(json["payload"]), symbolize_names: true), occurred_at: nil)
      end
    end
  end
end
