require "json"

module Hecks
  module Adapters
    class PostgresEra
      # The two-phase query path: candidate ids from the field caches, then the head view
      # restricted to them. The cache only narrows; the head view stays authoritative.
      module QueryPhases
        private

        # Phase one: candidate ids from the narrow cache tables, INTERSECTed. Reuses `where_clause`
        # against each cache's `value` column, so every operator `super` supports works here.
        def cache_phase(cached)
          binds = []
          clauses = cached.map do |clause, value|
            cache_table = @lineage.field_cache(table, @era, clause.field.to_s)
            "SELECT id FROM #{quote_ident(cache_table)} WHERE #{where_clause(clause.op.to_s, quote_ident("value"), value, binds,
                                                                             field: clause.field)}"
          end
          @db.exec_params(clauses.join("\nINTERSECT\n"), binds).map { |row| row["id"] }
        end

        # Phase two: the head view restricted to phase one's ids plus the clauses it could not
        # accelerate. Repeats the tail of `SqlQueryBuilder#query` so that module stays untouched.
        def head_phase(declared, uncached, ids, args)
          binds = []
          clauses = ["id IN (#{ids.map { |id| placeholder(binds, id) }.join(", ")})"]
          uncached.each { |clause, value| clauses << uncached_clause(clause, value, binds) }

          sql = "SELECT #{select_list} FROM #{from_relation} WHERE #{clauses.join(" AND ")}"
          sql += order_suffix(declared)
          sql += paging_suffix(declared, binds, args)
          execute_query(sql, binds)
        end

        # A clause cache phase could not serve: a null comparison's own predicate, else the
        # operator's `where_clause` against the head view.
        def uncached_clause(clause, value, binds)
          expression = query_expression(clause.field, value: value)
          null_predicate = QuerySpecification::Common::NullPolicy.sql_predicate(expression, clause.op, value)
          return null_predicate.first if null_predicate

          where_clause(clause.op.to_s, expression, value, binds, field: clause.field)
        end

        def order_suffix(declared)
          return " ORDER BY id" unless declared.order_by

          " ORDER BY #{order_clause(declared.order_by, declared.null_semantics)}"
        end

        def paging_suffix(declared, binds, args)
          limit = declared.limit && " LIMIT #{placeholder(binds, page_value(declared.limit, args))}"
          offset = declared.offset && " OFFSET #{placeholder(binds, page_value(declared.offset, args))}"
          unbounded = unbounded_limit if !declared.limit && declared.offset
          "#{limit}#{unbounded}#{offset}"
        end

        def page_value(bound, args) = query_value(bound.value, args).to_i
      end
    end
  end
end
