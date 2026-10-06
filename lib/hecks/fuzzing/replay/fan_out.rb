module Hecks
  module Fuzzing
    module Replay
      # Independent recomputation of what each `for_each` policy should have fanned out over.
      module FanOut
        # What one event's fan-out findings are computed against.
        Context = Struct.new(:runtime, :snapshot, :reactions_since)

        # One finding per (event, for_each policy) pair, independent of
        # `PolicyInterpreter#deliver_for_each`, answered via `Ports::Query::InMemory`
        # directly rather than `QueryInterpreter`, so this stays blind to nothing the
        # fan-out feature adds. `expected_row_ids` is `nil` when `where` did not hold.
        def fan_out_findings(runtime, snapshot, announced, reactions_since)
          context = Context.new(runtime, snapshot, reactions_since)
          announced.each_with_object([]) do |event, findings|
            # `event.aggregate` is domain-qualified ("Banking::Account"); split the same
            # two ways `PolicyInterpreter#policies_for` does.
            domain = event.aggregate.to_s.split("::").first
            bluebook = runtime.registry.bluebook(domain)
            next unless bluebook

            fanning_policies(bluebook, event).each do |policy|
              findings << fan_out_finding(context, policy, event, domain)
            end
          end
        end

        # The bluebook's `for_each` policies that react to `event`.
        def fanning_policies(bluebook, event)
          emitting = Naming.demodulise(event.aggregate)
          bluebook.policies.select do |policy|
            policy.fans_out? && policy.event_name == event.name &&
              (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
          end
        end

        # Builds one fan-out finding, comparing one `for_each` policy's independently
        # recomputed expected rows against what actually reacted for one event.
        def fan_out_finding(context, policy, event, domain)
          payload = event.payload.transform_keys(&:to_sym)
          held = policy.where.to_s.empty? || Bluebook::Expression::Evaluator.call(policy.where, {}, payload)
          expected = held ? expected_fan_out_rows(context.runtime, context.snapshot, policy, domain, payload) : nil

          { policy: policy.name, on: event.name, expected_row_ids: expected,
            actual_row_ids: reacted_rows(context.reactions_since, policy, event) }
        end

        # The rows the reaction log shows `policy` dispatching to for `event`.
        def reacted_rows(reactions_since, policy, event)
          reactions_since.select { |r| r[:policy] == policy.name && r[:on] == event.name }
                         .filter_map { |r| r[:for_row] }
        end

        # `policy.for_each`'s declared query, answered against the pre-dispatch snapshot
        # (the real fan-out's query runs before its own dispatched commands can mutate
        # anything it would match, so this must read the same "before" state). A `Symbol`
        # where-value binds to the triggering event's own payload; a literal is as declared.
        def expected_fan_out_rows(runtime, snapshot, policy, domain, payload)
          query_domain, aggregate_name, query_name = policy.for_each_route(domain)
          query = for_each_query(runtime, query_domain, aggregate_name, query_name)
          return [] unless query

          rows = snapshot[[query_domain, aggregate_name]] || {}
          matched = rows.select do |_id, state|
            query.wheres.all? { |clause| clause_holds?(clause, state, payload) }
          end

          matched.keys.map(&:to_s).sort
        end

        # The declared query a `for_each` policy names, or nil.
        def for_each_query(runtime, query_domain, aggregate_name, query_name)
          runtime.registry.bluebook(query_domain)&.aggregate(aggregate_name)&.query(query_name)
        end
      end
    end
  end
end
