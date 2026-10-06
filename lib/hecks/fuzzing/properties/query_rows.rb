module Hecks
  module Fuzzing
    module Properties
      # Recomputes which stored rows a query's `where` clauses admit, resolving reference hops
      # over the replay snapshot.
      module QueryRows
        # The stored instances a query is recomputed over, with the domain they are read in and
        # every loaded bluebook (to resolve reference hops).
        Snapshot = Struct.new(:instances, :domain, :bluebooks)

        # Recomputes which of an aggregate's own stored rows a query's `wheres` admit.
        #
        # Rows get `id:` merged in because Ordering.apply's `identity:` and the real answer
        # both use it. The snapshot's `bluebooks` are needed only to resolve a `/` hop clause.
        #
        # @param snapshot [Snapshot] `history[:instances]` or an `:instances_at` snapshot
        # @param aggregate_name [String] the aggregate whose rows are read
        # @param wheres [Array<QuerySpecification::Common::WhereClause>] clauses every row
        #   must satisfy
        # @param args [Hash] the query's call args, for clauses whose value is a Symbol
        # @return [Array<Hash>] each admitted row's state, merged with its `id:`
        def query_eligible_rows(snapshot, aggregate_name, wheres, args)
          aggregate = snapshot.bluebooks[snapshot.domain]&.aggregate(aggregate_name)
          prefix = "#{snapshot.domain}::#{aggregate_name}#"
          snapshot.instances.filter_map do |key, state|
            next unless key.start_with?(prefix)

            row = state.merge(id: key.split("#").last)
            row if wheres.all? { |clause| clause_holds?(snapshot, aggregate, clause, args, row) }
          end
        end

        # Whether `row` satisfies one clause, after resolving any reference hop in it.
        def clause_holds?(snapshot, aggregate, clause, args, row)
          resolved = resolve_hop_clause(snapshot, aggregate, clause, args)
          held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, resolved.field))
          Ports::Query::InMemory.holds?(resolved, held, args)
        end

        # Resolves one hop of a `/`-chained clause into a local `in` clause over the target's ids.
        #
        # Restates `Runtime::ReferenceHop#fold` over the replay snapshot, so the property never
        # checks the runtime against its own code path. A clause with no resolvable hop head
        # is returned unchanged.
        #
        # @param aggregate [Bluebook::Aggregate, nil] nil skips hop resolution
        # @return [QuerySpecification::Common::WhereClause] `clause`, or the `in` clause
        def resolve_hop_clause(snapshot, aggregate, clause, args)
          return clause unless aggregate && QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)

          hop, rest = QuerySpecification::HopPath.next_hop(clause.field, aggregate.attributes)
          return clause unless hop.target

          hop_in_clause(snapshot, hop, rest, clause, args)
        end

        # The `in` clause over the ids of the hop target's rows that satisfy the rest of the path.
        def hop_in_clause(snapshot, hop, rest, clause, args)
          inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
          ids   = query_eligible_rows(snapshot, hop.target.hecks_name, [inner], args).map { |row| row[:id].to_s }.uniq

          QuerySpecification::Common::WhereClause.new(field: hop.attribute.name, op: "in", value: ids)
        end
      end
    end
  end
end
