require_relative "ordering"
require_relative "../../runtime/value"
require_relative "../../query_specification/field_path"
require_relative "../../query_specification/common/comparison"

module Hecks
  module Ports
    module Query
      # Applies wheres, order_by, offset and limit to an Array of records, in the same order
      # as `SqlQueryBuilder` so every adapter answers the same page.
      module InMemory
        FieldPath = QuerySpecification::FieldPath
        Comparison = QuerySpecification::Common::Comparison

        module_function

        # Filters, orders and pages `records` against a declared query specification.
        #
        # @param records [Array<Runtime::Instance, Hash>] the candidates
        # @param declared [QuerySpecification::Common::Options] provides `wheres`, `order_by`,
        #   `offset` and `limit`
        # @param args [Hash{Symbol => Object}] values for Symbol placeholders
        # @param registry [Runtime::Registry, nil] passed to registry-aware comparisons
        # @return [Array<Runtime::Instance, Hash>] the matching records, ordered and paged
        def execute(records, declared, args = {}, registry: nil)
          matched = records.select do |record|
            declared.wheres.all? do |clause|
              holds?(clause, comparable(FieldPath.dig(record, clause.field)), args, registry: registry)
            end
          end
          field   = declared.order_by&.field
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
          # Offset before limit, as SQL means `LIMIT n OFFSET m`; the reverse order returns a short
          # or empty page (`limit 10, offset 10` would drop everything).
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched
        end

        def holds?(clause, held, args, registry: nil)
          Comparison.holds?(clause.op, held, comparable(resolve(clause.value, args)), registry: registry)
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value) = Comparison.comparable(value)
      end
    end
  end
end
