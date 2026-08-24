module Hecks
  module QuerySpecification
    module Common
      module NullPolicy
        module_function

        # STABLE on purpose : rows arrive already in identity order from
        # Ports::Query::Ordering, and that base is what makes a tie deterministic
        # rather than store-dependent. A plain sort_by is not stable in Ruby, so
        # equal keys would shuffle and the identity tier would be lost exactly
        # where it is needed. Descending reverses both partitions, so a tie reads
        # identity-descending too — the same total order sql_order renders as
        # `field DESC, id DESC`.
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

        def sql_order(expression, direction, policy)
          direction = direction.to_s.downcase == "desc" ? "DESC" : "ASC"
          nulls = case policy&.mode.to_s
                  when "first" then " NULLS FIRST"
                  when "last" then " NULLS LAST"
                  else ""
                  end
          "#{expression} #{direction}#{nulls}, id #{direction}"
        end

        # THE COMPARATORS A NULL CANNOT SATISFY — the other half of
        # `sql_predicate` below. That one answers "the value COMPARED TO is
        # null" (`eq: nil` -> IS NULL, `ne: nil` -> IS NOT NULL, a real
        # convention both adapters already shared). This one answers the
        # case nothing covered: the ROW'S OWN value is null and the value
        # compared to is not.
        #
        # SQL says unknown. `NULL <> 'red'` is NULL, not true, so the row
        # is not returned. Ruby says `nil != "red"` is true, so it is. The
        # two adapters therefore answered the SAME query on the SAME data
        # differently — Memory returning a row SQLite omitted — which is
        # not a difference of opinion a caller can plan around.
        #
        # Resolved toward SQL, and not because SQL is the store: an absent
        # or null field is UNKNOWN, not a value, and a comparison against
        # unknown is unknown rather than true. Making SQL match Ruby
        # instead would mean compiling every `ne:` to
        # `(col <> $1 OR col IS NULL)` — more to get right in two
        # dialects, and a reliable way to lose an index — to make a real
        # query engine agree with an in-memory one.
        #
        # `none_in_state` is deliberately NOT here: it is a 9th, vendored
        # comparator whose `held` is a reference id, and a row holding no
        # reference is genuinely "not in that state" rather than unknown.
        NULL_UNMATCHABLE = %w[eq ne lt lte gt gte in contains].freeze

        def unmatchable?(operation, held, want)
          held.nil? && !want.nil? && NULL_UNMATCHABLE.include?(operation.to_s)
        end

        def sql_predicate(expression, operation, value)
          if value.nil? && operation.to_s == "eq"
            ["#{expression} IS NULL", []]
          elsif value.nil? && operation.to_s == "ne"
            ["#{expression} IS NOT NULL", []]
          else
            nil
          end
        end
      end
    end
  end
end
