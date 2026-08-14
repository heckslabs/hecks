module Hecksagain
  module Bluebook
    module Behaviour
      # WHAT A POLICY DOES. Its declared half is four plain fields; these
      # are the readings taken off them.
      module Policy
        # The BLUEBOOK's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        def hecks_name = @name

        def event_qualifier = Naming.qualifier(@on_event)

        def event_name = Naming.unqualified(@on_event)

        # WHETHER THIS POLICY FANS OUT — `for_each` names a query, and a
        # non-empty one turns a single reaction into one dispatch per row
        # the query answers. Read by the interpreter that runs the fan-out
        # and by the property that checks it dispatched once per row.
        def fans_out? = !@for_each.to_s.empty?

        # WHETHER THIS POLICY IS GUARDED — a non-empty `where` decides
        # whether the policy fires at all, read against the triggering
        # event's own payload.
        def guarded? = !@where.to_s.empty?

        # THE FAN-OUT QUERY'S ROUTE, split the way the runtime runs it:
        # `[query_domain, aggregate_name, query_name]`. The query runs
        # against the triggering event's OWN domain unless `for_each`
        # names one ("Domain::Aggregate.query"). Deliberately independent
        # of `across`/`target_domain`, which name where `trigger` fires,
        # not where the fan-out's own query runs.
        def for_each_route(default_domain)
          path, query_name = @for_each.to_s.split(".", 2)
          domain, aggregate = path.to_s.include?("::") ? path.split("::", 2) : [default_domain.to_s, path]
          [domain, aggregate, query_name]
        end

        # THE ARGUMENT NAME THE FAN-OUT MINTS EACH MATCHED ROW'S ID UNDER —
        # the same `<aggregate>_id` mint `reference_to <Aggregate>` gives a
        # bare reference, so a `for_each` iterating Account and a command
        # written `reference_to Account` agree on the argument's name.
        def fan_out_reference_key(aggregate_name) = :"#{Naming.reference_key(aggregate_name)}_id"
      end
    end
  end
end
