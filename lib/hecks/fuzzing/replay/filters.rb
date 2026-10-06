require_relative "../../query_specification/common/comparators"
require_relative "../../query_specification/common/where_clause"
require_relative "../../query_specification/field_path"
require_relative "../../ports/query/in_memory"

module Hecks
  module Fuzzing
    module Replay
      # Answers the ad hoc `{aggregate:, field:, op:, value:}` filter steps that bypass the
      # declared query DSL.
      module Filters
        # Mirrors QuerySpecification::Common::COMPARATORS, not the Rust
        # kernel's own comparator enum, which is missing `none_in_state` and has drifted.
        FILTER_COMPARATORS = Hecks::QuerySpecification::Common::COMPARATORS.map(&:to_s).freeze

        # Answers one ad hoc filter step, the mirror image of kernel/cli.rs's own
        # `run_filter`, calling the same production `Ports::Query::InMemory` rather than
        # re-deriving comparator behavior by hand. Sorted by id ascending regardless,
        # since an ad hoc filter declares no order of its own.
        #
        # @raise [Bluebook::Expression::EvaluationError] if `op` or `"aggregate"` is unknown
        def run_filter(runtime, filter)
          check_comparator!(filter["op"].to_s)

          domain_name, aggregate = filter_aggregate(runtime, filter["aggregate"].to_s)
          clause  = filter_clause(filter)
          records = runtime.registry.repository(domain_name, aggregate).all

          rows_by_id(records.select { |record| clause_holds?(clause, record, {}) })
        end

        # A malformed ad-hoc ask is a fault (C8.3), not a bare RuntimeError.
        def check_comparator!(comparator)
          return if FILTER_COMPARATORS.include?(comparator)

          raise Bluebook::Expression::EvaluationError, "unknown query comparator #{comparator.inspect}"
        end

        def filter_clause(filter)
          QuerySpecification::Common::WhereClause.new(field: filter["field"].to_s, op: filter["op"].to_s, value: filter["value"])
        end

        # The records as `{id:, **state}` rows, sorted by id ascending.
        def rows_by_id(records)
          records.sort_by { |record| record.id.to_s }.map { |record| { id: record.id }.merge(record.state) }
        end

        # The domain name and aggregate a filter's `"Domain::Aggregate"` reference names.
        #
        # @raise [Bluebook::Expression::EvaluationError] if no such aggregate is loaded
        def filter_aggregate(runtime, aggregate_ref)
          domain_name, aggregate_name = aggregate_ref.split("::", 2)
          aggregate = runtime.registry.bluebook(domain_name)&.aggregate(aggregate_name)
          raise Bluebook::Expression::EvaluationError, "unknown aggregate #{aggregate_ref.inspect}" unless aggregate

          [domain_name, aggregate]
        end

        # Whether `subject`'s value at the clause's field satisfies the clause, `args` binding
        # any Symbol value.
        def clause_holds?(clause, subject, args)
          held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(subject, clause.field))
          Ports::Query::InMemory.holds?(clause, held, args)
        end

        # Builds the `refusals` entry's own "verb" column for a refused ad hoc filter,
        # which carries no real verb to report.
        def filter_label(filter) = "filter #{filter["aggregate"]}.#{filter["field"]} #{filter["op"]}"
      end
    end
  end
end
