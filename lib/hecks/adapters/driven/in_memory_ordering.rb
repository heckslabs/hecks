require_relative "../../ports/query/in_memory"
require_relative "../../ports/query/ordering"
require_relative "../../query_specification/common/order_by"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"

module Hecks
  module Adapters
    # Shared by every adapter that holds decoded Ruby records rather than
    # running real SQL (Memory, Lambda, Heki) — the identical dotted-path
    # value-object member-picking Postgres/Sqlite/D1's own
    # order_expression does (numeric member wins, else the one-field
    # convention "value"), just walked in Ruby instead of compiled to a
    # JSONB/json_extract path, because there is no query engine
    # underneath any of these three to hide that walk inside.
    module InMemoryOrdering
      module_function

      # Sorts a decoded-record Array by a declared attribute, or leaves it alone when no
      # ordering is given, with identity (`id`) as the tie-break.
      #
      # order_by is a runtime value (an HTTP query param, in the
      # console's case), not framework-authored bluebook source — see
      # postgres.rb's own all for the full reasoning. Whitelisted the
      # identical way before FieldPath.dig ever runs.
      #
      # @param records [Array<Runtime::Instance>] the records to sort; not mutated
      # @param aggregate [Bluebook::Aggregate] the aggregate whose attributes `order_by` is
      #   checked against
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by; nil returns `records` unchanged
      # @param direction [Symbol, String] `:asc` or `:desc`
      # @return [Array<Runtime::Instance>] `records` in the requested order, or unchanged
      #   when `order_by` is nil
      # @raise [Runtime::WiringError] if `order_by` names no attribute of `aggregate`
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

      # Resolves the dotted path to walk when sorting by a declared field, picking a
      # value object's numeric member (or its sole attribute, or the `value` convention)
      # when the field itself names a value object rather than a scalar.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate `field` is declared on
      # @param field [String, Symbol] the attribute (or dotted value-object path) to sort by
      # @return [String] the dotted path to dig a record with, unchanged from `field` when it
      #   already names a path, or names a scalar attribute, or names no attribute at all
      def sortable_path(aggregate, field)
        name, *path = field.to_s.split(".")
        return field.to_s unless path.empty?

        attribute = aggregate.attribute(name)
        return field.to_s if aggregate.lifecycle&.field.to_s == name || attribute.nil?

        vo = aggregate.value_object(attribute.type)
        return field.to_s unless vo

        # Numeric member first, then the sole attribute whatever it is
        # named (single-attribute value objects strictly answer `.value`
        # — the same generalization `SqlQueryBuilder#query_expression`
        # makes for the column side, kept in lockstep so Memory and SQL
        # order the identical rows identically), and only then the bare
        # `value` convention — now purely a backstop for the multi-field
        # non-numeric shape neither rule can honestly pick a field for.
        member = vo.attributes.find { |a| %w[Integer Float].include?(a.type) }&.name ||
                 vo.sole_attribute&.name || "value"
        "#{name}.#{member}"
      end
    end
  end
end
