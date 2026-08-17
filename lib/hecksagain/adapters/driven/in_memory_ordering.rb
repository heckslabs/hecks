require_relative "../../ports/query/in_memory"
require_relative "../../ports/query/ordering"
require_relative "../../query_specification/common/order_by"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"

module Hecksagain
  module Adapters
    # SHARED BY every adapter that holds decoded Ruby records rather than
    # running real SQL (Memory, Lambda, Heki) — the identical dotted-path
    # value-object member-picking Postgres/Sqlite/D1's own
    # order_expression does (numeric member wins, else the one-field
    # convention "value"), just walked in Ruby instead of compiled to a
    # JSONB/json_extract path, because there is no query engine
    # underneath any of these three to hide that walk inside.
    module InMemoryOrdering
      module_function

      # order_by IS A RUNTIME VALUE (an HTTP query param, in the
      # console's case), not framework-authored bluebook source — see
      # postgres.rb's own all for the full reasoning. Whitelisted the
      # identical way before FieldPath.dig ever runs.
      def ordered(records, aggregate:, order_by:, direction:)
        return records unless order_by

        name = order_by.to_s.split(".").first
        raise Runtime::WiringError, "#{aggregate.name} has no attribute #{order_by.inspect} to order by" unless aggregate.lifecycle&.field.to_s == name || aggregate.attribute(name)

        path = sortable_path(aggregate, order_by)
        spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
        Ports::Query::Ordering.apply(records, spec, nil, identity: ->(record) { record.id.to_s }) do |record|
          Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(record, path))
        end
      end

      def sortable_path(aggregate, field)
        name, *path = field.to_s.split(".")
        return field.to_s unless path.empty?

        attribute = aggregate.attribute(name)
        return field.to_s if aggregate.lifecycle&.field.to_s == name || attribute.nil?

        vo = aggregate.value_object(attribute.type)
        return field.to_s unless vo

        member = vo.attributes.find { |a| %w[Integer Float].include?(a.type) }&.name || "value"
        "#{name}.#{member}"
      end
    end
  end
end
