require_relative "ordering"
require_relative "cursor"
require_relative "../../runtime/value"
require_relative "../../query_specification/field_path"
require_relative "../../query_specification/common/comparison"

module Hecks
  module Ports
    module Query
      # Applies wheres, order_by, a cursor's position, offset and limit to an Array of records, in the same order
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
          matched = filter(records, declared, args, registry)
          page(order(matched, declared), declared, args)
        end

        # The cursor's position, then the offset, then the limit.
        #
        # Offset before limit, as SQL means `LIMIT n OFFSET m`; the reverse order returns a short
        # or empty page (`limit 10, offset 10` would drop everything).
        def page(ordered, declared, args)
          ordered = Cursor.after(ordered, declared, args) if declared.cursor
          ordered = ordered.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          declared.limit ? ordered.first(resolve(declared.limit.value, args).to_i) : ordered
        end

        def filter(records, declared, args, registry)
          records.select do |record|
            declared.wheres.all? do |clause|
              holds?(clause, comparable(FieldPath.dig(record, clause.field)), args, registry: registry)
            end
          end
        end

        def order(matched, declared)
          order_by = declared.order_by
          field = order_by&.field
          Ordering.apply(matched, order_by, declared.null_semantics,
                         identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
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
