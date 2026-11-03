module Hecks
  module Bluebook
    module Behaviour
      # Readings over a policy's declared fields.
      module Policy
        # The bluebook's name for this construct.
        #
        # @return [String]
        def hecks_name = @name

        # The domain-and-aggregate prefix of the triggering event's name.
        #
        # @return [String, nil] the part of `on_event` before its first `.`, or `nil` if none
        def event_qualifier = Naming.qualifier(@on_event)

        # The triggering event's bare name, without its prefix.
        #
        # @return [String]
        def event_name = Naming.unqualified(@on_event)

        # Whether this policy puts a need to the outside by name rather than triggering a command.
        #
        # @return [Boolean]
        def asks? = !@ask.to_s.empty?

        # What the policy reaches, as a reader names it: the trigger, or the ask while no
        # hecksagon has bound it to a port operation.
        #
        # @return [String]
        def reaches = @trigger_command.to_s.empty? && asks? ? "ask :#{@ask}" : @trigger_command.to_s

        # Binds an `ask` to the verb the hecksagon's declared ask resolves to, so everything
        # that reads `trigger_command` reads the port operation the old spelling named.
        #
        # @param verb [String] the resolved `Aggregate::Port.Operation`
        # @return [String] the verb
        def resolve_ask!(verb) = @trigger_command = verb

        # The wire form: an ask policy carries `ask` where a trigger policy carries
        # `trigger_command`, and a trigger policy carries no `ask` key at all, so the pinned
        # shape of every existing policy does not move.
        #
        # @return [Hash] the policy's IR
        def to_h
          shape = super
          return shape.except(:ask) unless asks?

          shape.except(:ask).to_h { |key, value| key == :trigger_command ? [:ask, @ask] : [key, value] }
        end

        # Whether `for_each` names a query, turning one reaction into a dispatch per row.
        #
        # @return [Boolean]
        def fans_out? = !@for_each.to_s.empty?

        # Whether a non-empty `where` decides if the policy fires at all.
        #
        # @return [Boolean]
        def guarded? = !@where.to_s.empty?

        # The structured form of `where`, memoized because a policy is consulted once per event.
        #
        # @return [Hash, nil] `nil` when the policy is not guarded
        def where_ast
          if defined?(@where_ast)
            @where_ast
          else
            (@where_ast = guarded? ? Expression::AstJson.emit_predicate(@where) : nil)
          end
        end

        # The guard as a rule for `Evaluator.call_rule`; it has no description because an
        # unmet `where` is a silent skip.
        #
        # @return [Bluebook::Given]
        def where_rule = @where_rule ||= Given.new(description: nil, canonical: @where, ast: where_ast)

        # The fan-out query's route, split the way the runtime runs it.
        #
        # The query runs in the triggering event's domain unless `for_each` names one
        # ("Domain::Aggregate.query"); it is independent of `across`/`target_domain`.
        #
        # @param default_domain [String, Symbol] the triggering event's domain
        # @return [Array(String, String, String)] `[domain, aggregate_name, query_name]`
        def for_each_route(default_domain)
          path, query_name = @for_each.to_s.split(".", 2)
          domain, aggregate = path.to_s.include?("::") ? path.split("::", 2) : [default_domain.to_s, path]
          [domain, aggregate, query_name]
        end

        # The argument name for each fan-out row's id is not minted here: it depends on the
        # target command's declared shape, so it lives on `Behaviour::Command#addressing_key_for`.
      end
    end
  end
end
