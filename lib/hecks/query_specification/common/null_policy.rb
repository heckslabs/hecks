module Hecks
  module QuerySpecification
    module Common
      # Null-handling shared between the in-memory and SQL query
      # engines: stable null-aware ordering (#order, #sql_order) and
      # which comparators a null value can never satisfy (#unmatchable?,
      # #sql_predicate) — kept in one place because Memory, Postgres and
      # SQLite each default nulls differently and must be made to agree
      # explicitly rather than leaking their own native behavior.
      module NullPolicy
        module_function

        # Sorts records in memory by one key, placing the null-keyed ones where
        # the policy says and keeping ties in their incoming order.
        #
        # Stable on purpose : rows arrive already in identity order from
        # `Ports::Query::Ordering`, and that base is what makes a tie deterministic
        # rather than store-dependent. A plain sort_by is not stable in Ruby, so
        # equal keys would shuffle and the identity tier would be lost exactly
        # where it is needed. Descending reverses both partitions, so a tie reads
        # identity-descending too — the same total order sql_order renders as
        # `field DESC, id DESC`.
        #
        # @param records [Array<Object>] the rows to order, already in identity order
        # @param direction [Symbol, String] `desc` sorts descending; anything else ascending
        # @param policy [NullSemantics, nil] where nulls go: mode `first` or `last`; `nil` or
        #   any other mode (`native`) puts nulls first ascending and last descending
        # @yield reads the sort key out of one record
        # @yieldparam record [Object] one element of `records`
        # @yieldreturn [Comparable, nil] the key, mutually comparable across records; `nil`
        #   marks the record as null-keyed
        # @return [Array<Object>] a new Array holding every record in the requested order
        # @raise [ArgumentError] if two non-nil keys cannot be compared with each other
        def order(records, direction:, policy: nil, &key)
          null_rows, valued_rows = records.partition { |record| key.call(record).nil? }
          sorted = valued_rows.each_with_index.sort_by { |record, index| [key.call(record), index] }.map(&:first)
          if direction.to_s == "desc"
            sorted.reverse!
            null_rows.reverse!
          end
          case policy&.mode.to_s
          when "first" then null_rows + sorted
          when "last" then sorted + null_rows
          else direction.to_s == "desc" ? sorted + null_rows : null_rows + sorted
          end
        end

        # Renders the `ORDER BY` terms for one expression, with an explicit
        # `NULLS FIRST`/`NULLS LAST` and an `id` tiebreak in the same direction.
        #
        # M3 — an undeclared (`native`) null policy still renders a
        # `NULLS ...` clause. Rendering none leaves each dialect's own
        # default to decide: Postgres puts nulls last on ASC (and first
        # on DESC), while `#order` above — this same "native" default,
        # for Memory — puts nulls first on ASC (and last on DESC), the
        # SQLite convention. Same query, same data, different row order
        # depending only on which adapter ran it. Rendered explicitly
        # here instead, so an undeclared policy means the same total
        # order everywhere rather than "whatever this store already does"
        # — matching `#order`'s own default rather than the other way
        # round, since that default is unconditional (Memory/Heki have no
        # dialect to defer to) and SQLite already agrees with it natively.
        #
        # @param expression [String] the SQL expression to order by, already quoted or
        #   built by the adapter; interpolated as is
        # @param direction [Symbol, String] `desc` in any letter case renders `DESC`;
        #   anything else `ASC`
        # @param policy [NullSemantics, nil] mode `first` or `last` pins the nulls; `nil` or
        #   any other mode renders `NULLS FIRST` ascending and `NULLS LAST` descending
        # @return [String] the terms without the `ORDER BY` keyword, such as
        #   `"price ASC NULLS FIRST, id ASC"`
        def sql_order(expression, direction, policy)
          direction = direction.to_s.downcase == "desc" ? "DESC" : "ASC"
          nulls = case policy&.mode.to_s
                  when "first" then " NULLS FIRST"
                  when "last" then " NULLS LAST"
                  else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                  end
          "#{expression} #{direction}#{nulls}, id #{direction}"
        end

        # **The comparators a NULL cannot satisfy** — the other half of
        # `sql_predicate` below. That one answers "the value compared to is
        # null" (`eq: nil` -> IS NULL, `ne: nil` -> IS NOT NULL, a real
        # convention both adapters already shared). This one answers the
        # case nothing covered: the row's own value is null and the value
        # compared to is not.
        #
        # SQL says unknown. `NULL <> 'red'` is NULL, not true, so the row
        # is not returned. Ruby says `nil != "red"` is true, so it is. The
        # two adapters therefore answered the same query on the same data
        # differently — Memory returning a row SQLite omitted — which is
        # not a difference of opinion a caller can plan around.
        #
        # Resolved toward SQL, and not because SQL is the store: an absent
        # or null field is unknown, not a value, and a comparison against
        # unknown is unknown rather than true. Making SQL match Ruby
        # instead would mean compiling every `ne:` to
        # `(col <> $1 OR col IS NULL)` — more to get right in two
        # dialects, and a reliable way to lose an index — to make a real
        # query engine agree with an in-memory one.
        #
        # `none_in_state` is deliberately not here: it is a 9th, vendored
        # comparator whose `held` is a reference id, and a row holding no
        # reference is genuinely "not in that state" rather than unknown.
        NULL_UNMATCHABLE = %w[eq ne lt lte gt gte in contains].freeze

        # Decides whether a comparison is lost before it starts because the row's
        # own value is null — the rule `NULL_UNMATCHABLE`'s comment argues for.
        #
        # @param operation [Symbol, String] the comparator name, such as `:ne`
        # @param held [Object, nil] the row's own value for the field
        # @param want [Object, nil] the value compared against
        # @return [Boolean] `true` when `held` is `nil`, `want` is not, and the comparator is
        #   one of `NULL_UNMATCHABLE`; `none_in_state` is never unmatchable
        def unmatchable?(operation, held, want)
          held.nil? && !want.nil? && NULL_UNMATCHABLE.include?(operation.to_s)
        end

        # Renders the SQL for a comparison against a null value — `eq: nil` as
        # `IS NULL`, `ne: nil` as `IS NOT NULL` — so an adapter never binds a
        # `NULL` parameter to `=` or `<>`.
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
