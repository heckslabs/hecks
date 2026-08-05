require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/field_path"
require_relative "../../runtime/errors"
require_relative "../../runtime/value"

module Hecksagain
  module Adapters
    # The one SQL query compilation, shared by the SQLite and Postgres
    # adapters — each used to carry its own copy of this walk, near-line-
    # identical, and the copies could only drift. Every declared operator
    # compiles fully into SQL or the query refuses loudly; the null-policy
    # predicate, the comma-separated `in` convention, and the identity
    # ORDER BY fallback are spelled once, here.
    #
    # What a dialect actually differs on is narrow, and each adapter
    # supplies exactly those hooks:
    #
    #   placeholder(binds, value)     — "?" or "$N", recording the bind
    #   contains_clause(expr, ph)     — instr() or position(), for a SCALAR field
    #   list_contains_clause(name, member, ph) — real element containment,
    #                                  for a `list_of` field (json_each /
    #                                  jsonb_array_elements)
    #   empty_in_clause               — "0" or "FALSE"
    #   comparable_expression(e, v)   — ::numeric cast, where the dialect casts
    #   plain_column(name)            — a real column or a jsonb path
    #   nested_expression(name, path, member) — json_extract or state #>>
    #   order_clause(order_by, policy)
    #   execute_query(sql, binds)     — run it, return instances
    #   dialect_name                  — for the refusal message
    module SqlQueryBuilder
      COMPARATORS = {
        "eq" => "=", "ne" => "<>", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<="
      }.freeze

      def query(declared, args = {}, context: {})
        sql = +"SELECT #{select_list} FROM #{from_relation}"
        clauses = []
        binds = []
        declared.wheres.each do |clause|
          value = query_value(clause.value, args)
          expression = query_expression(clause.field, value: value)
          if (null_predicate = QuerySpecification::Common::NullPolicy.sql_predicate(expression, clause.op, value))
            clauses << null_predicate.first
            next
          end
          clauses << where_clause(clause.op.to_s, expression, value, binds, field: clause.field)
        end
        sql << " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
        sql << if declared.order_by
                 " ORDER BY #{order_clause(declared.order_by, declared.null_semantics)}"
               else
                 " ORDER BY id"
               end
        sql << " LIMIT #{placeholder(binds, query_value(declared.limit.value, args).to_i)}" if declared.limit
        # An offset with no declared limit — SQLite refuses a bare OFFSET
        # outright (LIMIT -1 is its unbounded idiom) while Postgres accepts
        # one, so the dialect supplies its own unbounded spelling. Found by
        # the adapter-agreement gate on its first run, not by either
        # adapter's own spec: each was self-consistent, they just disagreed.
        sql << unbounded_limit if !declared.limit && declared.offset
        sql << " OFFSET #{placeholder(binds, query_value(declared.offset.value, args).to_i)}" if declared.offset
        execute_query(sql, binds)
      end

      private

      def where_clause(op, expression, value, binds, field: nil)
        case op
        when "eq", "ne", "gt", "gte", "lt", "lte"
          "#{comparable_expression(expression, value)} #{COMPARATORS.fetch(op)} #{placeholder(binds, value)}"
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

          "#{expression} IN (#{members.map { |member| placeholder(binds, member) }.join(', ')})"
        else
          raise ArgumentError, "#{dialect_name} query adapter does not support #{op.inspect}"
        end
      end

      # A REAL ARRAY ALREADY SAYS WHERE ITS MEMBERS END. Splitting one on
      # commas re-reads a boundary it already drew — and an id is a
      # domain value (Naming::IDENTITY_JOIN joins a composite identity's
      # own parts, and the parts it joins are whatever an identity path
      # pulled out of real data), so a name carrying a comma would
      # silently become two members matching the wrong rows, or nothing.
      # This branch used to call `value.to_s` unconditionally, which
      # meant only a comma-joined STRING ever worked here, while
      # Ports::Query::InMemory and QueryInterpreter's own `members`
      # already handled a real Array — three implementations of `in`,
      # two readings of it. Narrower than those two on one point,
      # deliberately: they unwrap a value-object/Hash element to its
      # own scalar first (`comparable`) before stringifying, a rule
      # this doesn't reproduce — every real caller of `in` today, and
      # the cross-aggregate hop this exists for, passes plain scalar
      # ids, never a value-object element.
      def in_members(value)
        return value.map(&:to_s).reject(&:empty?) if value.is_a?(Array)

        value.to_s.split(",").map(&:strip).reject(&:empty?)
      end

      # Every declared field compiles into an expression over the stored
      # shape — or the query never runs. The member-picking rules are the
      # same in both dialects: a value-object field compares through the
      # member the bound value (or the declared types) say is numeric,
      # falling back to the one-field convention `value`.
      #
      # A REFERENCE IS AN ID, stored as a bare scalar (never wrapped —
      # `Runtime::Value.refuse_object_reference` guarantees it), so it
      # takes the SAME plain-column path as any other non-value-object
      # attribute. Excluding it into the value-object member-picking logic
      # compiles a nested read against a row that has no nested key — a
      # path that can never match. Measured, not assumed: a `where` on a
      # has_one/belongs_to/reference_to field returned zero rows against
      # real data until that exclusion was removed.
      def query_expression(field, value: nil)
        name, *path = field.to_s.split(".")
        attribute = @aggregate.attribute(name)

        return plain_column(name) if path.empty? && @aggregate.lifecycle&.field.to_s == name
        return plain_column(name) if path.empty? && attribute && !value_object?(attribute)

        member = if path.empty? && value
                   hash = value.is_a?(Runtime::Value) ? value.to_h : value
                   numeric = hash.is_a?(Hash) && hash.find { |_key, item| item.is_a?(Numeric) }
                   numeric ? numeric.first : nil
                 end
        member ||= if path.empty? && attribute && value_object?(attribute)
                     object = @aggregate.value_object(attribute.type)
                     object.attributes.find { |candidate| %w[Integer Float].include?(candidate.type) }&.name
                   end
        nested_expression(name, path, member)
      end

      def query_value(value, args)
        value = args[value] if value.is_a?(Symbol)
        hash = value.is_a?(Runtime::Value) ? value.to_h : value
        return hash.find { |_key, item| item.is_a?(Numeric) }&.last if hash.is_a?(Hash)

        Runtime::Value.scalar(value)
      rescue Runtime::TypeMismatch
        value.is_a?(Hash) && value.size == 1 ? value.values.first : value
      end

      def value_object?(attr)
        !attr.list? && !@aggregate.value_object(attr.type).nil?
      end

      # `contains` on a `list_of` field means real ELEMENT membership, not
      # a substring search over the column's raw JSON text — the reading
      # QueryInterpreter#holds? and Ports::Query::InMemory already give a
      # real Array, and the SQL side used to disagree with it (a substring
      # match over `[{"value":"not_high_risk"}]` falsely matches
      # "high_risk"). Returns nil for a non-list field (the caller falls
      # back to `contains_clause`, unchanged), "" for a list of bare
      # scalars (no member to walk into), or the one field name a
      # single-field value-object element carries. A list of a
      # MULTI-field value object has no one scalar to compare against and
      # is refused rather than guessed.
      def list_member(field)
        return nil if field.to_s.include?(".")

        attribute = @aggregate.attribute(field.to_s)
        return nil unless attribute&.list?

        object = @aggregate.value_object(attribute.type)
        return "" unless object
        return object.attributes.first.name.to_s if object.attributes.size == 1

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
