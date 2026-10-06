require "json"

module Hecks
  module Adapters
    class PostgresEra
      # The SQL dialect `SqlQueryBuilder` compiles declared queries in, plus the two-phase
      # query path that narrows candidates through the field caches before reading the head view.
      module Dialect
        private

        def select_list = "id, state"
        def from_relation = quoted_head
        def dialect_name = "PostgresEra"
        def empty_in_clause = "FALSE"

        def placeholder(binds, value)
          binds << value
          "$#{binds.size}"
        end

        def contains_clause(expression, placeholder)
          "position(#{placeholder} in #{expression}) > 0"
        end

        def list_contains_clause(column, member, placeholder)
          target = member.empty? ? "elem #>> '{}'" : "elem ->> #{text_literal(member)}"
          elements = "jsonb_array_elements(state #> ARRAY[#{text_literal(column)}]::text[]) AS elem"
          "EXISTS (SELECT 1 FROM #{elements} WHERE #{target} = #{placeholder})"
        end

        def plain_column(name) = jsonb_path([name])

        def nested_expression(name, path, member)
          segments = path.empty? ? [name, (member || "value").to_s] : [name, *path]
          jsonb_path(segments)
        end

        def comparable_expression(expression, value)
          value.is_a?(Numeric) ? "(#{expression})::numeric" : expression
        end

        def execute_query(sql, binds)
          @db.exec_params(sql, binds).map { |row| instance(row) }
        end

        def instance(row)
          Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row["state"]))
        end

        # Reads every head row after `suffix`, as instances.
        def head_instances(suffix)
          @db.exec(%(SELECT id, state FROM #{quoted_head} #{suffix})).map { |row| instance(row) }
        end

        # Runs after SQL-side era translation, as the last step of every read.
        def decode(state_json)
          Ports::Persistence::StateCodec.decode(@aggregate, JSON.parse(state_json))
        end

        def quote_ident(name) = PG::Connection.quote_ident(name.to_s)
        def quoted_head = quote_ident(@lineage.head_view(table))
        def quoted_head_snapshot = quote_ident(@lineage.head_snapshot(table, @era))

        def order_expression(field)
          expression = query_expression(field)
          numeric_field?(field) ? "(#{expression})::numeric" : expression
        end

        # Postgres defaults to NULLS LAST on ASC; place nulls explicitly (first ascending, last
        # descending) so a declared query answers the same on every adapter.
        def order_clause(order_by, policy)
          direction = order_by.direction.to_s.downcase == "desc" ? "DESC" : "ASC"
          nulls = case policy&.mode.to_s
                  when "first" then " NULLS FIRST"
                  when "last" then " NULLS LAST"
                  else direction == "DESC" ? " NULLS LAST" : " NULLS FIRST"
                  end
          "#{order_expression(order_by.field)} #{direction}#{nulls}, id #{direction}"
        end

        # One shared walk decides numericness at any depth, so a nested path is not ordered as text.
        def numeric_field?(field)
          name, *path = field.to_s.split(".")
          QuerySpecification::FieldPath.numeric?(@aggregate.attribute(name), path) do |type|
            Runtime::Value.value_object_for(@aggregate, type)
          end
        end

        # `ARRAY[...]` of escaped literals, never the '{a,b}' syntax: that form has no escaping, so
        # a quote in a segment would become live SQL.
        def jsonb_path(segments)
          "state #>> ARRAY[#{segments.map { |segment| text_literal(segment) }.join(", ")}]::text[]"
        end

        def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

        # Where-fields of the aggregate's and its entities' queries that a cache table can
        # represent; order_by-only fields never needed a cache.
        def ensure_field_caches!
          cached_where_fields.to_h do |field|
            [field, @lineage.ensure_field_cache!(table, @era, field, query_expression(field))]
          end
        end

        def cached_where_fields
          fields = declared_queries.flat_map do |q|
            q.wheres.map do |clause|
              clause.field.to_s
            end
          end
          fields.uniq.select { |field| cacheable_field?(field) }
        end

        def declared_queries
          @aggregate.queries + @aggregate.entities.flat_map(&:queries)
        end

        # List fields are excluded: a one-value cache row cannot hold `contains` membership.
        def cacheable_field?(field)
          name = field.to_s.split(".").first
          return true if @aggregate.lifecycle&.field.to_s == name

          attribute = @aggregate.attribute(name)
          !attribute.nil? && !attribute.list?
        end

        # A clause is cache-served when its field has a cache table and it is not a null comparison,
        # which `NullPolicy` intercepts before `where_clause`.
        def cache_eligible?(clause, value)
          @field_caches.key?(clause.field.to_s) &&
            QuerySpecification::Common::NullPolicy.sql_predicate(query_expression(clause.field, value: value), clause.op,
                                                                 value).nil?
        end
      end
    end
  end
end
