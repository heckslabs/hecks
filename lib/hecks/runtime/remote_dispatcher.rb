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
    # Dispatcher for a domain whose `.world` declares Lambda routing.
    # Same public shape as `Dispatcher`; writes go remote, reads stay local.
    #
    # Reads delegate to a local `Dispatcher` because the registry's repositories are
    # already Lambda-backed. Writes cannot: givens and constraints must run in Rust,
    # not be pre-checked here against incomplete local state.
    class RemoteDispatcher
      Result = Struct.new(:verb, :instance, :events, :refused_reactions, :blocking_reactions,
                          :reaction_defects, keyword_init: true) do
        # Lists the policy reactions this dispatch caused that the routed runtime refused.
        #
        # @return [Array<Hash{Symbol => Object}>] one `{ policy:, trigger:, reason: }` per refused
        #   reaction, oldest first; empty when every reaction was delivered
        def refused_reactions = self[:refused_reactions] || []

        # Lists the refused reactions that block the run, as opposed to a benign non-match.
        #
        # @return [Array<Hash{Symbol => Object}>] the subset of `refused_reactions` that blocks
        def blocking_reactions = self[:blocking_reactions] || []

        # @return [Array<Hash{Symbol => Object}>] the reactions the host reported as crashed
        def reaction_defects = self[:reaction_defects] || []

        # The settled record's identity.
        #
        # @return [String]
        def id    = instance.id

        # The settled record's attributes.
        #
        # @return [Hash{Symbol => Object}] `:id` merged in last
        def state = instance.to_h
      end

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry this dispatcher fronts
      # @param region [String] the AWS region the routed Lambda function lives in
      # @param function [String, nil] the `dispatched_by("Lambda")` function name; nil
      #   resolves it from `ENV["DOMAIN_NAME"]` or `registry.root`
      def initialize(registry, region: "us-east-1", function: nil)
        @registry = registry
        # ENV["DOMAIN_NAME"] first: inside a deployed Lambda `root` is always
        # `/var/task`, which would resolve the function name to "task".
        @client = Adapters::Lambda::Client.new(domain: ENV["DOMAIN_NAME"] || File.basename(registry.root),
                                               region: region, function: function)
        @local = Dispatcher.new(registry)
      end

      # Dispatches a command by verb, locally or through the routed Lambda depending
      # on the aggregate's bound adapter.
      #
      # @param verb [String] the fully qualified verb, `"Domain::Aggregate.Command"`
      # @param saga_correlation [Hash, nil] correlation head => value stamped on emitted events
      # @param args [Hash] the facts, plus optional `:to`/`:with` keys
      # @return [RemoteDispatcher::Result] the verb, settled instance and emitted events
      # @raise [Runtime::UnknownVerb] if the verb is not fully qualified or names an
      #   undeclared domain or aggregate
      # @raise [Runtime::RemoteRefusal] if the routed Lambda refuses the call
      # @raise [Runtime::WiringError] if the adapter cannot be resolved, or the remote call
      #   reports no mutation for the aggregate
      def dispatch(verb, saga_correlation: nil, **args)
        dispatch_flat(verb, args.merge(saga_correlation: saga_correlation))
      end

      # Same routing as `dispatch`, with the flat-facts wire form of `Dispatcher#dispatch_flat`.
      #
      # @param verb [String] the fully qualified verb
      # @param args [Hash] the facts, plus optional Symbol keys `:to`, `:with`, `:saga_correlation`
      # @return [RemoteDispatcher::Result] the verb, settled instance and emitted events
      def dispatch_flat(verb, args = {})
        args = args.dup
        saga_correlation = args.delete(:saga_correlation)
        domain, aggregate_name, = Naming.split_verb(verb) ||
                                  raise(UnknownVerb,
                                        RefusalWording.render_site("UnknownVerb", "not_fully_qualified", verb: verb))
        aggregate = @registry.bluebook(domain)&.aggregate(aggregate_name) ||
                    raise(UnknownVerb,
                          RefusalWording.render_site("UnknownVerb", "no_aggregate", domain: domain, aggregate: aggregate_name))

        # Not every aggregate in a routed domain is Lambda-bound (a `compute` rule can
        # only run against Postgres). Test the adapter's capability, not its name.
        adapter_name = Ports::Persistence::BindingPolicy.resolve(@registry, domain, aggregate).adapter
        unless @registry.adapter_class(adapter_name) <= Ports::Persistence::RemoteRuntime
          return @local.dispatch_flat(verb, args.merge(saga_correlation: saga_correlation))
        end

        response = @client.dispatch(verb, args)

        refusal = response.fetch("refusals", []).find { |r| r["verb"] == verb }
        raise RemoteRefusal, "#{verb} refused: #{refusal["error"]}" if refusal

        # `mutations` has one entry per replayed step, so `.last` is this step. Match by
        # aggregate name: a reaction can mutate other aggregates in the same step.
        fqn = "#{domain}::#{aggregate.hecks_name}"
        mutation = response.fetch("mutations", []).last&.find { |m| m["aggregate"] == fqn } ||
                   raise(WiringError,
                         "#{verb} was accepted but rust/host reported no mutation for #{fqn} — response: #{response.inspect}")

        instance = Instance.new(aggregate: aggregate, id: mutation["id"],
                                state: JSON.parse(JSON.generate(mutation["state"]), symbolize_names: true))

        Result.new(verb: verb, instance: instance, events: step_events(response),
                   refused_reactions: refused_reactions_of(response),
                   blocking_reactions: ReactionOutcome.blocking(step_reactions(response)),
                   reaction_defects: ReactionOutcome.defects(step_reactions(response)))
      end

      # Delegates to the local `Dispatcher`; see `Dispatcher#query`.
      def query(verb, **args)           = @local.query(verb, **args)

      # Delegates to the local `Dispatcher`; see `Dispatcher#reference_query`.
      def reference_query(verb, **args) = @local.reference_query(verb, **args)

      # Fetches the domain's whole event history from the routed Lambda on every call.
      # Uncached: nothing calls it on a hot path.
      #
      # @return [Array<Runtime::Event>] every journaled event, oldest first, with
      #   `occurred_at` always nil
      def events
        @client.read.fetch("events", []).map { |e| build_event(e) }
      end

      private

      # The newest step's reactions the remote runtime refused, from its `reactions_per_step`
      # log (the whole-run `reactions` would also carry the replayed history's).
      def refused_reactions_of(response)
        step_reactions(response)
          .select { |entry| entry["delivered"] == false }
          .map { |entry| { policy: entry["policy"], trigger: entry["trigger"], reason: entry["reason"] } }
      end

      # Every reaction the newest step caused, delivered or not.
      def step_reactions(response) = Array(response.fetch("reactions_per_step", []).last)

      def step_events(response)
        response.fetch("events", []).map { |e| build_event(e) }
      end

      # The kernel's event JSON carries no timestamp, so `occurred_at` stays nil
      # rather than a synthesized `Time.now`.
      def build_event(json)
        Event.new(name: json["name"], aggregate: json["aggregate"], id: json["id"],
                  payload: JSON.parse(JSON.generate(json["payload"]), symbolize_names: true), occurred_at: nil)
      end
    end
  end
end
