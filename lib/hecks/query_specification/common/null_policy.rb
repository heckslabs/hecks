module Hecks
  module QuerySpecification
    module Common
      # Null handling shared by the in-memory and SQL query engines: null-aware ordering
      # and the comparators a null can never satisfy, so every adapter agrees.
      module NullPolicy
        module_function

        # Sorts records in memory by one key, placing the null-keyed ones where
        # the policy says and keeping ties in their incoming order.
        #
        # Stable on purpose: rows arrive in identity order, which makes ties deterministic.
        # Descending reverses both partitions, matching `sql_order`'s `field DESC, id DESC`.
        #
        # @param records [Array<Object>] the rows to order, already in identity order
        # @param direction [Symbol, String] `desc` sorts descending; anything else ascending
        # @param policy [NullSemantics, nil] mode `first` or `last`; otherwise `native`
        # @yieldparam record [Object] one element of `records`
        # @yieldreturn [Comparable, nil] the sort key; `nil` marks the record null-keyed
        # @return [Array<Object>] a new Array in the requested order
        def order(records, direction:, policy: nil, &key)
          descending = direction.to_s.downcase == "desc"
          null_rows, valued_rows = records.partition { |record| yield(record).nil? }
          sorted = valued_rows.each_with_index.sort_by { |record, index| [yield(record), index] }.map(&:first)
          if descending
            sorted.reverse!
            null_rows.reverse!
          end
          case policy&.mode.to_s
          when "first" then null_rows + sorted
          when "last" then sorted + null_rows
          else descending ? sorted + null_rows : null_rows + sorted
          end
        end

        # Renders the `ORDER BY` terms for one expression, with an explicit
        # `NULLS FIRST`/`NULLS LAST` and an `id` tiebreak in the same direction.
        #
        # An undeclared (`native`) policy still renders `NULLS ...`, because dialects
        # differ (Postgres puts nulls last on ASC); this matches `#order`'s default.
        #
        # @param expression [String] the SQL expression, interpolated as is
        # @param direction [Symbol, String] `desc` renders `DESC`; anything else `ASC`
        # @param policy [NullSemantics, nil] mode `first` or `last` pins the nulls
        # @return [String] the terms without `ORDER BY`, such as `"price ASC NULLS FIRST, id ASC"`
        def sql_order(expression, direction, policy)
          direction = direction.to_s.downcase == "desc" ? "DESC" : "ASC"
          nulls = case policy&.mode.to_s
                  when "first" then " NULLS FIRST"
                  when "last" then " NULLS LAST"
                  else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                  end
          "#{expression} #{direction}#{nulls}, id #{direction}"
        end

        # Comparators a NULL row value can never satisfy.
        #
        # SQL treats `NULL <> 'red'` as unknown, so the row is dropped; Memory follows SQL.
        # `none_in_state` is excluded: a row with no reference is not in that state.
        NULL_UNMATCHABLE = %w[eq ne lt lte gt gte in contains].freeze

        # Decides whether a comparison is lost because the row's own value is null.
        #
        # @param operation [Symbol, String] the comparator name, such as `:ne`
        # @param held [Object, nil] the row's own value for the field
        # @param want [Object, nil] the value compared against
        # @return [Boolean] `true` when `held` is `nil`, `want` is not, and the comparator is
        #   one of `NULL_UNMATCHABLE`; `none_in_state` is never unmatchable
        def unmatchable?(operation, held, want)
          held.nil? && !want.nil? && NULL_UNMATCHABLE.include?(operation.to_s)
        end

        # Renders the SQL for a comparison against a null value (`IS NULL`/`IS NOT NULL`),
        # so an adapter never binds a `NULL` parameter to `=` or `<>`.
        #
        # @param expression [String] the SQL expression for the field, interpolated as is
        # @param operation [Symbol, String] the comparator name
        # @param value [Object, nil] the resolved value compared against
        # @return [Array(String, Array), nil] the predicate text and its (empty) bind
        #   parameters; `nil` when `value` is not `nil` or the comparator is neither `eq`
        #   nor `ne`, leaving the adapter to render the clause itself
        def sql_predicate(expression, operation, value)
          if value.nil? && operation.to_s == "eq"
            ["#{expression} IS NULL", []]
          elsif value.nil? && operation.to_s == "ne"
            ["#{expression} IS NOT NULL", []]
          end
        end
      end
    end
  end
end
