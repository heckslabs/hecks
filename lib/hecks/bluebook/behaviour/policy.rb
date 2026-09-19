module Hecks
  module Bluebook
    module Behaviour
      # **What a policy does**. Its declared half is four plain fields; these
      # are the readings taken off them.
      module Policy
        # The bluebook's name for this construct, asked the same way of a class
        # that has crossed over and of an IR object that has not. Collapses into
        # Construct when this one crosses.
        #
        # @return [String, nil] the policy's declared name, or `nil` before it is set
        def hecks_name = @name

        # Names the domain the triggering event is qualified with, if any.
        #
        # @return [String, nil] the qualifier of `on_event` (the part before the first
        #   `.`), or `nil` if `on_event` is unqualified
        def event_qualifier = Naming.qualifier(@on_event)

        # Names the triggering event, stripped of any domain qualifier.
        #
        # @return [String] `on_event` with its qualifier, if any, removed
        def event_name = Naming.unqualified(@on_event)

        # Whether this policy fans out — `for_each` names a query, and a
        # non-empty one turns a single reaction into one dispatch per row
        # the query answers. Read by the interpreter that runs the fan-out
        # and by the property that checks it dispatched once per row.
        #
        # @return [Boolean] whether this policy declares a `for_each` query
        def fans_out? = !@for_each.to_s.empty?

        # Whether this policy is guarded — a non-empty `where` decides
        # whether the policy fires at all, read against the triggering
        # event's own payload.
        #
        # @return [Boolean] whether this policy declares a `where` guard
        def guarded? = !@where.to_s.empty?

        # The structured form of `where`, derived once — the same tree
        # `AstJson.emit_predicate` spells for every rule row, memoized
        # here because a policy is consulted once per event, not once per
        # boot. Nil when there is no `where`, exactly as the wire carries
        # it.
        #
        # @return [Hash, nil] the guard's AST as `AstJson.emit_predicate` renders it, or
        #   `nil` if this policy declares no `where`
        def where_ast
          if defined?(@where_ast)
            @where_ast
          else
            (@where_ast = guarded? ? Expression::AstJson.emit_predicate(@where) : nil)
          end
        end

        # The rule-shaped reading of the guard, for `Evaluator.call_rule`
        # — a policy's `where` has no description (nothing refuses with
        # it; an unmet where is a silent skip).
        #
        # @return [Bluebook::Given] the guard wrapped as a `Given`, with `description: nil`
        def where_rule = @where_rule ||= Given.new(description: nil, canonical: @where, ast: where_ast)

        # The fan-out query's route, split the way the runtime runs it:
        # `[query_domain, aggregate_name, query_name]`. The query runs
        # against the triggering event's own domain unless `for_each`
        # names one ("Domain::Aggregate.query"). Deliberately independent
        # of `across`/`target_domain`, which name where `trigger` fires,
        # not where the fan-out's own query runs.
        #
        # @param default_domain [String, Symbol] the triggering event's own domain, used
        #   when `for_each` names no domain
        # @return [Array(String, String, String)] `[query_domain, aggregate_name, query_name]`
        def for_each_route(default_domain)
          path, query_name = @for_each.to_s.split(".", 2)
          domain, aggregate = path.to_s.include?("::") ? path.split("::", 2) : [default_domain.to_s, path]
          [domain, aggregate, query_name]
        end

        # The argument name a fan-out dispatch mints each matched row's id
        # under depends on the target command's own declared shape, not on
        # the aggregate name alone, so this policy does not answer it
        # directly: it lives on `Behaviour::Command#addressing_key_for`,
        # asked of the resolved target command by
        # `PolicyInterpreter#addressing_key_for`.
      end
    end
  end
end
