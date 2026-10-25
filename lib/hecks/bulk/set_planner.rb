require_relative "../naming"
require_relative "../literal"
require_relative "../bluebook/expression"
require_relative "../ports/persistence/set_statement"
require_relative "../runtime/command_rules"
require_relative "../runtime/errors"
require_relative "../runtime/query_interpreter"
require_relative "../runtime/value"
require_relative "set_eligibility"
require_relative "set_arguments"

module Hecks
  module Bulk
    # Says a bulk run as one {Ports::Persistence::SetStatement}, or answers nil when it must run
    # row by row (ADR 0128). It reads only the bluebook and the run; whether each expression has
    # SQL is the store's to answer when it compiles.
    class SetPlanner
      include SetEligibility

      # @param registry [Runtime::Registry] the registry the run's domain is booted in
      # @param plan [Bulk::Plan] the run
      # @param key [Symbol] the argument a row's id fills
      def initialize(registry, plan, key)
        @registry = registry
        @plan = plan
        @domain, aggregate_name, @command_name = Naming.split_verb(plan.verb)
        @aggregate = registry.bluebook(@domain).aggregate(aggregate_name)
        @command = @aggregate.command(@command_name)
        @repository = registry.repository(@domain, @aggregate)
        @arguments = SetArguments.new(@aggregate, @command, key)
      end

      # @return [Bulk::SetArguments] the arguments each row's dispatch would carry
      attr_reader :arguments

      # The run as one statement, or nil when part of it cannot be one.
      #
      # @return [Ports::Persistence::SetStatement, nil]
      def statement
        return nil unless same_aggregate? && eligible? && role_held?

        query, query_args = store_query
        query && build(query, query_args)
      rescue *Runtime::DOMAIN_REFUSALS, Runtime::WiringError
        nil
      end

      private

      def same_aggregate?
        query_domain, query_aggregate, = @plan.query_route
        query_domain == @domain && query_aggregate == @aggregate.hecks_name
      end

      # The command's role is the caller's, the same for every row, so it is asked once.
      def role_held?
        Runtime::CommandRules.new(@registry).refuse_role_mismatch(@command, @domain)
        true
      end

      def store_query
        _, _, query_name = @plan.query_route
        args = @plan.query_arguments(@aggregate.query(query_name))
        Runtime::QueryInterpreter.new(@registry).store_specification(@domain, @aggregate, query_name, args)
      end

      def build(query, query_args)
        Ports::Persistence::SetStatement.new(
          query: query, query_args: query_args, arguments: @arguments.scalars,
          givens: @command.givens.map { |given| Bluebook::Expression::Evaluator.nodes_for(given) },
          assignments: @command.mutations.map { |mutation| assignment(mutation) },
          transition: transition, from_guard: from_guard
        )
      end

      def assignment(mutation)
        kind, value = assigned(mutation)
        Ports::Persistence::SetStatement::Assignment.new(target: mutation.target.to_s, kind: kind, value: value)
      end

      def assigned(mutation)
        source = mutation.source
        return [:step, @arguments.step(mutation)] unless mutation.op == :set
        return [:copy, source.name.to_s] if source.is_a?(StateRef)
        return [:expression, Bluebook::Expression::Resolver.parse(source.text)] if source.is_a?(Computed)

        [:constant, Runtime::Value.for(@aggregate, mutation.target, @arguments.source_value(source))]
      end

      def transition
        cases = @aggregate.lifecycle&.transitions_for(@command.hecks_name) || []
        cases.empty? ? nil : cases.map { |move| [move_from(move), move.target] }
      end

      def move_from(move) = (Array(move.from) if move.constrained?)

      def from_guard = (Array(@command.from) if @command.from && @aggregate.lifecycle)
    end
  end
end
