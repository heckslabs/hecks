module Hecks
  module Adapters
    class Sqlite
      # SQLite's own dialect hooks for the shared `SqlQueryBuilder`, plus
      # the identifier-quoting/table-naming helpers most of the rest of
      # `Sqlite` leans on — split out only to keep the `Sqlite` class body
      # under its line budget, not because these are any less part of it;
      # every method here stays private on `Sqlite` instances exactly as
      # if it were still defined there.
      module Dialect
        private

        def select_list = "*"
        def from_relation = quoted_table
        def dialect_name = "SQLite"
        def empty_in_clause = "0"

        def placeholder(binds, value)
          binds << value
          "?"
        end

        def contains_clause(expression, placeholder)
          "instr(#{expression}, #{placeholder}) > 0"
        end

        def list_contains_clause(column, member, placeholder)
          target = member.empty? ? "json_each.value" : "json_extract(json_each.value, '$.#{member}')"
          "EXISTS (SELECT 1 FROM json_each(#{quote_ident(column)}) WHERE #{target} = #{placeholder})"
        end

        def plain_column(name) = quote_ident(name)

        def nested_expression(name, path, member)
          json_path = path.empty? ? "$.#{member || 'value'}" : "$.#{path.join('.')}"
          "json_extract(#{quote_ident(name)}, '#{json_path}')"
        end

        # SQLite has no bare OFFSET — LIMIT -1 is its own documented
        # unbounded spelling, exactly for this case.
        def unbounded_limit = " LIMIT -1"

        def order_clause(order_by, policy)
          QuerySpecification::Common::NullPolicy.sql_order(query_expression(order_by.field), order_by.direction, policy)
        end

        def execute_query(sql, binds)
          @db.execute(sql, binds).map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
        end

        def quote_ident(name)
          %("#{name.to_s.gsub('"', '""')}")
        end

        def quoted_table = quote_ident(table)
        def entry_table = "#{table}_entries"
        def quoted_entry_table = quote_ident(entry_table)
      end
    end
  end
end
