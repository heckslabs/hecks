require_relative "../../forms/value_object_shape"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"
require_relative "../../runtime/value"

module Hecks
  module Adapters
    # The SQL query compilation shared by the SQLite and Postgres adapters. Each dialect
    # supplies hooks: placeholder, contains_clause, list_contains_clause, empty_in_clause,
    # comparable_expression, plain_column, nested_expression, order_clause, execute_query
    # and dialect_name.
    module SqlQueryBuilder
      COMPARATORS = {
        "eq" => "=", "ne" => "<>", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<="
      }.freeze

      # Compiles a declared query into one SQL statement and runs it through the dialect's
      # own `execute_query`, so filtering, ordering and paging all happen in the database.
      #
      # @param declared [QuerySpecification::Common::Options] the declared query: its
      #   `wheres`, `order_by`, `limit` and `offset` are compiled; nothing else is read
      # @param args [Hash{Symbol => Object}] values for the specification's symbolic operands
      # @param context [Hash] execution context from `Ports::Query.execute`; accepted for the
      #   port's call shape and not read
      # @return [Array<Runtime::Instance>] the matching records in declared order, then by
      #   id; `[]` when none match
      # @raise [ArgumentError] if a where clause uses an operator this builder cannot compile,
      #   or `contains` targets a list of a value object with more than one field
      def query(declared, args = {}, context: {})
        sql = "SELECT #{select_list} FROM #{from_relation}"
        binds = []
        clauses = where_clauses(declared, args, binds)
        sql << " WHERE #{clauses.join(" AND ")}" unless clauses.empty?
        sql << order_by_sql(declared)
        sql << " LIMIT #{placeholder(binds, query_value(declared.limit.value, args).to_i)}" if declared.limit
        # SQLite refuses a bare OFFSET, so the dialect spells its own unbounded limit.
        sql << unbounded_limit if !declared.limit && declared.offset
        sql << " OFFSET #{placeholder(binds, query_value(declared.offset.value, args).to_i)}" if declared.offset
        execute_query(sql, binds)
      end

      private

      # `binds` is filled in place so LIMIT/OFFSET placeholders follow the where binds.
      def where_clauses(declared, args, binds)
        declared.wheres.each_with_object([]) do |clause, clauses|
          value = query_value(clause.value, args)
          expression = query_expression(clause.field, value: value)
          if (null_predicate = QuerySpecification::Common::NullPolicy.sql_predicate(expression, clause.op, value))
            clauses << null_predicate.first
            next
          end
          clauses << where_clause(clause.op.to_s, expression, value, binds, field: clause.field)
        end
      end

      def order_by_sql(declared)
        return " ORDER BY #{order_clause(declared.order_by, declared.null_semantics)}" if declared.order_by

        " ORDER BY id"
      end

      def where_clause(oper, expression, value, binds, field: nil)
        case oper
        when "eq", "ne", "gt", "gte", "lt", "lte"
          "#{comparable_expression(expression, value)} #{COMPARATORS.fetch(oper)} #{placeholder(binds, value)}"
        when "contains"
          member = field && list_member(field)
          if member
            list_contains_clause(field.to_s, member, placeholder(binds, value.to_s))
          else
            contains_clause(expression, placeholder(binds, value.to_s))
          end
        when "in"
          members = in_members(value)
          return empty_in_clause if members.empty?

          # `in` reads as text everywhere: casting the column keeps a numeric field
          # matching the stringified members (SQLite's json_extract carries no affinity).
          "CAST(#{expression} AS TEXT) IN (#{members.map { |member| placeholder(binds, member) }.join(", ")})"
        else
          raise ArgumentError, "#{dialect_name} query adapter does not support #{oper.inspect}"
        end
      end

      # A real array is not re-split on commas: an id is a domain value and may hold one.
      # Unlike the other engines, a Hash or value-object element is not unwrapped.
      def in_members(value)
        return value.map(&:to_s).reject(&:empty?) if value.is_a?(Array)

        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      # Compiles a declared field into an expression over the stored shape. A value-object
      # field compares through its numeric member, else its sole attribute, else `value`.
      # A reference is a bare id, so it takes the plain-column path.
      # The two member fallbacks stay in one method so their order is visible.
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      def query_expression(field, value: nil)
        name, *path = field.to_s.split(".")
        attribute = @aggregate.attribute(name)

        return plain_column(name) if path.empty? && @aggregate.lifecycle&.field.to_s == name
        return plain_column(name) if path.empty? && attribute && !value_object?(attribute)

        member = if path.empty? && value
                   hash = value.is_a?(Runtime::Value) ? value.to_h : value
                   numeric = hash.is_a?(Hash) && hash.find { |_key, item| item.is_a?(Numeric) }
                   # `numeric` can be false, which `&.` does not guard.
                   # rubocop:disable-next Style/SafeNavigation
                   numeric ? numeric.first : nil
                 end
        member ||= if path.empty? && attribute && value_object?(attribute)
                     object = Runtime::Value.value_object_for(@aggregate, attribute.type)
                     # A single-attribute value object is its one field, whatever it is named.
                     (Forms::ValueObjectShape.numeric_member(object) || object.sole_attribute)&.name
                   end
        nested_expression(name, path, member)
      end

      # Picks the same member `query_expression` does, so both sides of a comparison
      # agree on which field they mean.
      def query_value(value, args)
        value = args[value] if value.is_a?(Symbol)
        hash = value.is_a?(Runtime::Value) ? value.to_h : value
        if hash.is_a?(Hash)
          numeric = hash.find { |_key, item| item.is_a?(Numeric) }
          return numeric.last if numeric
          return hash[:value] if hash.key?(:value)
          return hash.values.first if hash.size == 1
        end

        Runtime::Value.scalar(value)
      rescue Runtime::TypeMismatch
        value.is_a?(Hash) && value.size == 1 ? value.values.first : value
      end

      def value_object?(attr)
        !attr.list? && !Runtime::Value.value_object_for(@aggregate, attr.type).nil?
      end

      # `contains` on a list means element membership, not a substring search over JSON text.
      # Returns nil for a non-list field, "" for bare scalars, else the sole member name.
      # Raises for a multi-field value object.
      def list_member(field)
        return nil if field.to_s.include?(".")

        attribute = @aggregate.attribute(field.to_s)
        return nil unless attribute&.list?

        object = Runtime::Value.value_object_for(@aggregate, attribute.type)
        return "" unless object
        return object.sole_attribute.name.to_s if object.sole_attribute

        raise ArgumentError,
              "#{dialect_name} query adapter cannot compile contains on #{field} — " \
              "#{attribute.type} carries more than one field, so no single scalar to compare"
      end

      # The dialect that casts nothing overrides nothing.
      def comparable_expression(expression, _value) = expression

      # The dialect that accepts a bare OFFSET overrides nothing.
      def unbounded_limit = ""
    end
  end
end
