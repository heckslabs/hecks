require_relative "../../forms/value_object_shape"
require_relative "../../ports/query/in_memory"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"
require_relative "../../text"
require_relative "../../runtime/value"
require_relative "sql_value_members"

module Hecks
  module Adapters
    # The SQL query compilation shared by the SQLite and Postgres adapters. Each dialect
    # supplies hooks: placeholder, contains_clause, list_contains_clause, empty_in_clause,
    # comparable_expression, plain_column, nested_expression, order_clause, execute_query
    # and dialect_name.
    module SqlQueryBuilder
      include SqlValueMembers

      COMPARATORS = {
        "eq" => "=", "ne" => "<>", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<="
      }.freeze

      # The operators answered from this store's records in Ruby, not compiled. `none_in_state`
      # reads another aggregate's records through the registry, which one SQL statement over this
      # aggregate's table cannot reach. Any other operator this builder cannot compile refuses.
      IN_MEMORY_OPERATORS = %w[none_in_state].freeze

      # Compiles a declared query into one SQL statement and runs it through the dialect's
      # own `execute_query`, so filtering, ordering and paging all happen in the database. A
      # query with a where clause in `IN_MEMORY_OPERATORS` is answered over `all` instead.
      #
      # @param declared [QuerySpecification::Common::Options] the declared query: its
      #   `wheres`, `order_by`, `limit` and `offset` are compiled; nothing else is read
      # @param args [Hash{Symbol => Object}] values for the specification's symbolic operands
      # @param context [Hash] execution context from `Ports::Query.execute`; its `:registry` is
      #   read only for a query answered over `all`
      # @return [Array<Runtime::Instance>] the matches in declared order, then by id; `[]` if none
      # @raise [ArgumentError] if a where clause uses an operator this builder cannot compile,
      #   or `contains` targets a list of a value object with more than one field
      def query(declared, args = {}, context: {})
        return in_memory_answer(declared, args, context) if in_memory?(declared)

        sql = "SELECT #{select_list} FROM #{from_relation}"
        binds = []
        clauses = where_clauses(declared, args, binds)
        sql << " WHERE #{clauses.join(" AND ")}" unless clauses.empty?
        sql << order_by_sql(declared)
        sql << paging_sql(declared, args, binds)
        execute_query(sql, binds)
      end

      private

      def in_memory?(declared) = declared.wheres.any? { |clause| IN_MEMORY_OPERATORS.include?(clause.op.to_s) }

      def in_memory_answer(declared, args, context)
        Ports::Query::InMemory.execute(all, declared, args, registry: context[:registry])
      end

      # The LIMIT and OFFSET text, with their placeholders bound after the where binds.
      def paging_sql(declared, args, binds)
        sql = +""
        sql << bound_paging(" LIMIT", declared.limit, args, binds) if declared.limit
        # SQLite refuses a bare OFFSET, so the dialect spells its own unbounded limit.
        sql << unbounded_limit if !declared.limit && declared.offset
        sql << bound_paging(" OFFSET", declared.offset, args, binds) if declared.offset
        sql
      end

      def bound_paging(keyword, clause, args, binds)
        "#{keyword} #{placeholder(binds, query_value(clause.value, args).to_i)}"
      end

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
        when "contains" then contains_sql(expression, value, binds, field)
        when "in" then in_sql(expression, value, binds)
        else
          raise ArgumentError, "#{dialect_name} query adapter does not support #{oper.inspect}"
        end
      end

      def contains_sql(expression, value, binds, field)
        member = field && list_member(field)
        if member
          list_contains_clause(field.to_s, member, placeholder(binds, value.to_s))
        else
          contains_clause(expression, placeholder(binds, value.to_s))
        end
      end

      def in_sql(expression, value, binds)
        members = in_members(value)
        return empty_in_clause if members.empty?

        # `in` reads as text everywhere: casting the column keeps a numeric field
        # matching the stringified members (SQLite's json_extract carries no affinity).
        "CAST(#{expression} AS TEXT) IN (#{members.map { |member| placeholder(binds, member) }.join(", ")})"
      end

      # A real array is not re-split on commas: an id is a domain value and may hold one.
      # Unlike the other engines, a Hash or value-object element is not unwrapped.
      def in_members(value)
        return value.map(&:to_s).reject(&:empty?) if value.is_a?(Array)

        Text.comma_list(value)
      end

      # Compiles a declared field into an expression over the stored shape. A value-object
      # field compares through its numeric member, else its sole attribute, else `value`.
      # A reference is a bare id, so it takes the plain-column path.
      def query_expression(field, value: nil)
        name, *path = field.to_s.split(".")
        attribute = @aggregate.attribute(name)

        return plain_column(name) if path.empty? && plain_field?(name, attribute)

        nested_expression(name, path, path.empty? ? expression_member(attribute, value) : nil)
      end

      # Whether a bare field name reads as one plain column: the lifecycle field, or a scalar.
      def plain_field?(name, attribute)
        @aggregate.lifecycle_field.to_s == name || (attribute && !value_object?(attribute))
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

        sole = object.sole_attribute
        return sole.name.to_s if sole

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
