require_relative "../../ports/query/cursor"

module Hecks
  module Adapters
    # The keyset predicate of a cursor query, compiled for the SQL dialects: the rows that follow
    # a position `(value, id)` in the query's own `ORDER BY`.
    #
    # `Ports::Query::Cursor` states the same rule over Ruby rows, so the two answer alike. Mixed
    # into {SqlQueryBuilder}; the dialect supplies `placeholder`, `query_expression`,
    # `comparable_expression` and, when it orders through its own expression, `order_expression`.
    module SqlKeyset
      private

      # @param declared [QuerySpecification::Common::Options] a query that may declare `cursor`
      # @param args [Hash] the ask's arguments; `:after` carries the token
      # @param binds [Array] filled in place, after the binds already there
      # @return [String, nil] the predicate, nil when the query has no cursor or no token
      def keyset_clause(declared, args, binds)
        position = declared.cursor && Ports::Query::Cursor.decode(args[:after])
        return unless position
        return "id > #{placeholder(binds, position.id)}" unless declared.order_by

        keyset_over_field(declared, position, binds)
      end

      def keyset_over_field(declared, position, binds)
        order_by = declared.order_by
        expression = keyset_expression(order_by.field, position.value)
        op = order_by.direction.to_s.downcase == "desc" ? "<" : ">"
        first = Ports::Query::Cursor.nulls_first?(order_by.direction, declared.null_semantics)
        return keyset_after_null(expression, op, first, position, binds) if position.value.nil?

        keyset_after_value(expression, op, first, position, binds)
      end

      # Rows that follow a null-keyed row: later nulls by id, and every valued row when nulls lead.
      def keyset_after_null(expression, op, nulls_first, position, binds)
        tied = "(#{expression} IS NULL AND id #{op} #{placeholder(binds, position.id)})"
        nulls_first ? "(#{tied} OR #{expression} IS NOT NULL)" : tied
      end

      # Rows that follow a valued row: later values, equal values with a later id, and the nulls
      # when they trail.
      def keyset_after_value(expression, op, nulls_first, position, binds)
        beyond = "#{expression} #{op} #{placeholder(binds, position.value)}"
        tied = "(#{expression} = #{placeholder(binds, position.value)} AND id #{op} #{placeholder(binds, position.id)})"
        nulls_first ? "(#{beyond} OR #{tied})" : "(#{beyond} OR #{tied} OR #{expression} IS NULL)"
      end

      def keyset_expression(field, value)
        expression = respond_to?(:order_expression, true) ? order_expression(field) : query_expression(field, value: value)
        comparable_expression(expression, value)
      end
    end
  end
end
