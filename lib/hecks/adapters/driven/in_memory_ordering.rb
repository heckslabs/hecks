require_relative "../../ports/query/in_memory"
require_relative "../../ports/query/ordering"
require_relative "../../query_specification/common/order_by"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"

module Hecks
  module Adapters
    # Ordering for adapters that hold decoded Ruby records (Memory, Lambda, Heki),
    # mirroring the SQL adapters' value-object member picking.
    module InMemoryOrdering
      module_function

      # Orders decoded records by a declared attribute, then by id as the tiebreaker.
      #
      # `order_by` may come from an HTTP query param, so it is checked before `FieldPath.dig`.
      #
      # @param records [Array<Runtime::Instance>] the records to order
      # @param aggregate [Bluebook::Aggregate] the aggregate `records` belong to
      # @param order_by [String, Symbol, nil] a dotted attribute path; nil returns `records` as-is
      # @param direction [Symbol] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] `records`, ordered by `order_by` then id
      # @raise [Runtime::WiringError] if `order_by` names no attribute of `aggregate` and is
      #   not its lifecycle field
      def ordered(records, aggregate:, order_by:, direction:)
        return records unless order_by

        name = order_by.to_s.split(".").first
        unless aggregate.lifecycle&.field.to_s == name || aggregate.attribute(name)
          raise Runtime::WiringError,
                "#{aggregate.name} has no attribute #{order_by.inspect} to order by"
        end

        path = sortable_path(aggregate, order_by)
        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        Ports::Query::Ordering.apply(records, spec, nil, identity: ->(record) { record.id.to_s }) do |record|
          Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(record, path))
        end
      end

      # Resolves the dotted path `FieldPath.dig` should read to compare a value object field.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate `field` belongs to
      # @param field [String, Symbol] a dotted order_by path, such as `"price"` or
      #   `"price.cents"`
      # @return [String] `field` unchanged for an already-dotted path, the lifecycle field, or
      #   an attribute with no value-object type; otherwise `"<name>.<member>"` naming the
      #   attribute's numeric member, its sole member, or the bare `"value"` convention
      def sortable_path(aggregate, field)
        name, *path = field.to_s.split(".")
        return field.to_s unless path.empty?

        attribute = aggregate.attribute(name)
        return field.to_s if aggregate.lifecycle&.field.to_s == name || attribute.nil?

        vo = aggregate.value_object(attribute.type)
        return field.to_s unless vo

        # Numeric member, else the sole attribute, else `value`; kept in lockstep with
        # `SqlQueryBuilder#query_expression` so Memory and SQL order rows identically.
        member = vo.attributes.find { |a| %w[Integer Float].include?(a.type) }&.name ||
                 vo.sole_attribute&.name || "value"
        "#{name}.#{member}"
      end
    end
  end
end
