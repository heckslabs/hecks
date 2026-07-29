module Hecksagain
  module QuerySpecification
    module Common
      module NullPolicy
        module_function

        def order(records, direction:, policy: nil, &key)
          null_rows, valued_rows = records.partition { |record| key.call(record).nil? }
          sorted = valued_rows.sort_by { |record| key.call(record) }
          sorted.reverse! if direction.to_s == "desc"
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
