module Hecks
  module Adapters
    class Postgres
      # Postgres's hooks into the shared SqlQueryBuilder, plus identifier quoting.
      module Dialect
        private

        def select_list = "*"
        def from_relation = quoted_table
        def dialect_name = "Postgres"
        def empty_in_clause = "FALSE"

        def placeholder(binds, value)
          binds << value
          "$#{binds.size}"
        end

        def contains_clause(expression, placeholder)
          "position(#{placeholder} in #{expression}) > 0"
        end

        # `column` is already a real jsonb column and already the array — no shared
        # `state` blob to walk into first, unlike PostgresEra's own version.
        def list_contains_clause(column, member, placeholder)
          target = member.empty? ? "elem #>> '{}'" : "elem ->> #{text_literal(member)}"
          elements = "jsonb_array_elements(#{quote_ident(column)}) AS elem"
          "EXISTS (SELECT 1 FROM #{elements} WHERE #{target} = #{placeholder})"
        end

        def plain_column(name) = quote_ident(name)

        # The attribute name is the column itself here, not part of the path (unlike
        # PostgresEra's shared `state` blob) — the path is whatever follows the column.
        def nested_expression(name, path, member)
          segments = path.empty? ? [(member || "value").to_s] : path
          jsonb_path(name, segments)
        end

        # A jsonb-extracted value still comes out as text; cast it to compare/sort
        # numerically instead of lexicographically.
        def comparable_expression(expression, value)
          value.is_a?(Numeric) && jsonb_extraction?(expression) ? "(#{expression})::numeric" : expression
        end

        def execute_query(sql, binds)
          pg_exec_params(sql, binds).map { |row| instance_from_row(row) }
        end

        def quote_ident(name) = PG::Connection.quote_ident(name.to_s)
        def quoted_table = quote_ident(table)
        def entry_table = "#{table}_entries"
        def quoted_entry_table = quote_ident(entry_table)

        def jsonb_extraction?(expression) = expression.include?("#>>")

        def order_expression(field)
          expression = query_expression(field)
          jsonb_extraction?(expression) && numeric_field?(field) ? "(#{expression})::numeric" : expression
        end

        # Overrides Postgres's default NULLS LAST on ASC so every adapter answers
        # a declared query's null ordering identically.
        def order_clause(order_by, policy)
          direction = order_by.direction.to_s.downcase == "desc" ? "DESC" : "ASC"
          nulls = case policy&.mode.to_s
                  when "first" then " NULLS FIRST"
                  when "last" then " NULLS LAST"
                  else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                  end
          "#{order_expression(order_by.field)} #{direction}#{nulls}, id #{direction}"
        end

        # Same walk PostgresEra's own numeric_field? uses — decides
        # numericness at any depth from the declared shape itself, not a
        # runtime value.
        def numeric_field?(field)
          name, *path = field.to_s.split(".")
          QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
            Runtime::Value.value_object_for(@aggregate, type)
          end
        end

        # Builds an escaped Array[...] literal rather than a hand-rolled '{a,b,c}'
        # string, since a segment name isn't guaranteed schema-declared.
        def jsonb_path(column, segments)
          "#{quote_ident(column)} #>> ARRAY[#{segments.map { |segment| text_literal(segment) }.join(", ")}]::text[]"
        end

        def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"
      end
    end
  end
end
