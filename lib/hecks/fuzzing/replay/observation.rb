module Hecks
  module Fuzzing
    module Replay
      # What a session reads off the runtime: the final history and the pre-dispatch snapshot a
      # `for_each` fan-out is checked against. Mixed into `Session`.
      module Observation
        private

        def observed_history
          { instances: Replay.snapshot_instances(@runtime), events: events, refusals: @refusals,
            reactions: @runtime.reactions, sagas: @runtime.sagas, saga_instances: saga_instances,
            queries: @queries, dry_runs: @dry_runs, dry_run_traces: @dry_run_traces,
            fan_outs: @fan_outs, guard_checks: @guard_checks,
            mutation_traces: @mutation_traces, outbox_traces: @outbox_traces,
            saga_dispatches: @runtime.saga_dispatches, policy_dispatches: @runtime.policy_dispatches,
            bluebook: @runtime.registry.bluebooks.values.first,
            bluebooks: @runtime.registry.bluebooks.dup }
        end

        def events
          @runtime.events.map { |event| { name: event.name, aggregate: event.aggregate, id: event.id, payload: event.payload } }
        end

        # The live process-manager store, materialised to inert data (`{ pm_name =>
        # { correlation => { state:, memory: } } }`), captured here because the
        # runtime goes out of scope with the boot and the Memory rebind leaves no
        # real saga store for Properties.sagas_rehydrate_cleanly to read otherwise.
        def saga_instances
          @runtime.registry.saga_instances.each_with_object({}) do |(pm_name, conversations), out|
            out[pm_name] = conversations.each_with_object({}) do |(correlation, instance), rows|
              rows[correlation] = { state: instance[:state], memory: Runtime::Value.materialize(instance[:memory]) }
            end
          end
        end

        # Every `[domain, aggregate_name]` a `for_each` policy could query, resolved
        # once from every loaded bluebook's own fanning-out policies. Empty when no
        # domain declares `for_each`, so the snapshot taken before each dispatch costs
        # nothing until one does.
        def fan_out_targets
          @runtime.registry.bluebooks.each_with_object({}) do |(domain, bluebook), targets|
            bluebook.policies.select(&:fans_out?).each do |policy|
              query_domain, aggregate_name, = policy.for_each_route(domain)
              targets[[query_domain, aggregate_name]] ||= @runtime.registry.bluebook(query_domain)&.aggregate(aggregate_name)
            end
          end
        end

        def fan_out_snapshot
          @fan_out_targets.each_with_object({}) do |((fdomain, faggregate_name), aggregate), snap|
            next unless aggregate

            snap[[fdomain, faggregate_name]] =
              @runtime.registry.repository(fdomain, aggregate).all.to_h { |record| [record.id, record.state.dup] }
          end
        end
      end
    end
  end
end
