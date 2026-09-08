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
    # THE WRITE-SIDE HALF OF LAMBDA ROUTING — `Runtime::Loader.boot`
    # constructs this INSTEAD OF `Dispatcher` when the booted domain's
    # own `.world` declares Lambda routing (see loader.rb's own
    # `dispatcher_class_for`). Matches `Dispatcher`'s public shape
    # closely enough that everything built ON TOP of a dispatcher —
    # `Handle`, `AggregateDoor`, `Facade::Surface` — needs no changes
    # at all: `Handle#run`'s entire contract is
    # `@dispatcher.dispatch("#{fqn}.#{command}", **identity, **args).instance.state`,
    # and both classes answer that identically.
    #
    # READS DELEGATE, WRITES DON'T. `query`/`reference_query` hand off
    # to a REAL `Dispatcher` built over the SAME registry — since that
    # registry's own repositories are ALREADY Lambda-backed
    # (`Adapters::Lambda`, `persisted_by("Lambda")`, Phase 2's other
    # half), the inherited query machinery (`QueryInterpreter`,
    # `Ports::Query::InMemory.execute`) works completely unchanged, no
    # query logic duplicated here. `dispatch` can't delegate the same
    # way: command validation (givens, constraints) has to actually
    # run in Rust for a Lambda-routed domain, not get pre-checked here
    # against incomplete local state and then merely persisted.
    class RemoteDispatcher
      Result = Struct.new(:verb, :instance, :events, keyword_init: true) do
        def id    = instance.id
        def state = instance.to_h
      end

      attr_reader :registry

      def initialize(registry, region: "us-east-1")
        @registry = registry
        # `File.basename(registry.root)`, not `bluebooks.keys.first` —
        # matches `Adapters::Lambda`'s own function-name resolution
        # exactly (see its own comment on why: one merged Lambda per
        # deploy, not one per attached chapter, and `root` is the one
        # signal every bluebook in this registry shares regardless of
        # which one attached it) — INCLUDING that same adapter's own
        # `ENV["DOMAIN_NAME"]`-first fix: `root` is always `/var/task`
        # inside a deployed Lambda, giving "task" instead of the real
        # domain name (a real, live AccessDeniedException on
        # "hecks-task" caught this).
        @client = Adapters::Lambda::Client.new(domain: ENV["DOMAIN_NAME"] || File.basename(registry.root), region: region)
        # READ-SIDE DELEGATE ONLY (see class comment) — never dispatched
        # through; a real Dispatcher's own `query`/`reference_query`
        # already resolve generically via `registry.repository(...)`,
        # so building one here reuses that instead of duplicating it.
        @local = Dispatcher.new(registry)
      end

      def dispatch(verb, saga_correlation: nil, **args)
        domain, aggregate_name, = Naming.split_verb(verb) ||
                                  raise(UnknownVerb,
                                        RefusalWording.render("UnknownVerb", "not_fully_qualified", verb: verb.inspect))
        aggregate = @registry.bluebook(domain)&.aggregate(aggregate_name) ||
                    raise(UnknownVerb,
                          RefusalWording.render("UnknownVerb", "no_aggregate", domain: domain, aggregate: aggregate_name.inspect))

        # NOT EVERY AGGREGATE IN A LAMBDA-ROUTED DOMAIN IS ITSELF
        # LAMBDA-BOUND — Member's real name->email rekey carries a
        # `compute` rule (era_check.rb's own `check_compute_rules!`),
        # which can only ever run against Postgres, permanently. Its
        # OWN `.hecksagon` bind stays "Postgres" even when
        # `dispatched_by("Lambda")` is on for everything else — checked
        # here by real CAPABILITY (`Ports::Persistence::RemoteRuntime`,
        # §1), not by comparing the adapter's own name to the string
        # "Lambda" — a bind resolves to whatever adapter CLASS actually
        # backs it, and only a class shaped like "the real interpreter
        # lives behind a call boundary" forwards here; anything else
        # (Postgres, Memory, any future local adapter) falls through to
        # the real local Dispatcher instead of being forwarded to a
        # Lambda that has no way to represent its lineage history at
        # all.
        adapter_name = Ports::Persistence::BindingPolicy.resolve(@registry, domain, aggregate).adapter
        unless @registry.adapter_class(adapter_name) <= Ports::Persistence::RemoteRuntime
          return @local.dispatch(verb, saga_correlation: saga_correlation, **args)
        end

        response = @client.dispatch(verb, args)

        refusal = response.fetch("refusals", []).find { |r| r["verb"] == verb }
        raise RemoteRefusal, "#{verb} refused: #{refusal['error']}" if refusal

        # THIS STEP'S OWN mutations — `mutations` is one entry per
        # replayed step (rust/host's rehydrate-and-replay design,
        # Phase 1), so `.last` is exactly the step just dispatched.
        # Matched by fully-qualified aggregate name, not just "the
        # first mutation" — a command whose reaction ALSO mutates a
        # different aggregate (a policy, a saga leg) puts more than
        # one mutation in the same step, and the direct effect of
        # THIS verb is the one this dispatch's own caller expects
        # `.instance` to be.
        fqn = "#{domain}::#{aggregate.hecks_name}"
        mutation = response.fetch("mutations", []).last&.find { |m| m["aggregate"] == fqn } ||
                   raise(WiringError,
                         "#{verb} was accepted but rust/host reported no mutation for #{fqn} — response: #{response.inspect}")

        instance = Instance.new(aggregate: aggregate, id: mutation["id"],
                                state: JSON.parse(JSON.generate(mutation["state"]), symbolize_names: true))

        Result.new(verb: verb, instance: instance, events: step_events(response))
      end

      def query(verb, **args)           = @local.query(verb, **args)
      def reference_query(verb, **args) = @local.reference_query(verb, **args)

      # THE FULL DOMAIN'S EVENT HISTORY, on every call — `{"read":
      # true}` replays the whole journal (Phase 1's `dispatch::read`),
      # so its own `events` array already IS the complete log, the
      # same thing `@registry.event_log` would answer for a local
      # dispatch. Not cached: `AggregateDoor.events`/`Handle#events`
      # are not called in this codebase's own hot paths today: if that
      # changes, caching belongs here, not in every caller.
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
