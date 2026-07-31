module Hecksagain
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
