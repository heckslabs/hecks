module Hecks
  module Fuzzing
    module Properties
      # Properties that check a query's answer against an independent recomputation.
      module Querying
        # Differential oracle: each replayed ask is answered natively and by the reference
        # interpreter, and the two must agree.
        #
        # Refusal is read by key presence (`:error` / `:reference_error`), not truthiness;
        # one side refusing while the other answers is a divergence. Read-model asks
        # (no "::" in the verb) have no reference twin and are skipped.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true, or a message naming each disagreeing query
        def query_answers_match_reference(history)
          offenders = history.fetch(:queries).filter_map do |asked|
            next unless asked[:query].is_a?(String) && asked[:query].include?("::")

            native_refused    = asked.key?(:error)
            reference_refused = asked.key?(:reference_error)

            if native_refused != reference_refused
              next "#{asked[:query]} #{asked[:args].inspect} — native " \
                   "#{native_refused ? "refused (#{asked[:error]})" : 'answered'}, " \
                   "but the reference interpreter #{reference_refused ? "refused (#{asked[:reference_error]})" : 'answered'} — " \
                   "a refusal-shaped divergence, not just a differing row set"
            end

            next if native_refused
            next if asked[:rows] == asked[:reference_rows]

            "#{asked[:query]} #{asked[:args].inspect} answered #{asked[:rows].inspect} " \
              "natively but #{asked[:reference_rows].inspect} through the reference interpreter"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Recomputes order/offset/limit from `history[:instances]` and compares it with the
        # real answer of every paged query (`order_by` with `offset` or `limit`).
        #
        # Ordering reuses `Ports::Query::Ordering.apply` so "in order" cannot drift from the
        # interpreter; only the offset-then-limit slice is restated. Comparing the interpreter's
        # native and reference paths instead could share one bug.
        #
        # Kept as one method: the steps run once, in order, and share every intermediate.
        # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true, or a message naming each mismatching query
        def paging_offset_partitions_correctly(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:queries).filter_map do |asked|
            next if asked[:error] || !asked[:query].is_a?(String) || !asked[:query].include?("::")

            declared = query_for_verb(bluebooks, asked[:query])
            next unless declared&.order_by && (declared.offset || declared.limit)

            domain, aggregate_name, = Naming.split_verb(asked[:query])
            args = asked[:args] || {}
            rows = query_eligible_rows(asked.fetch(:instances_at), domain, aggregate_name, declared.wheres, args,
                                       bluebooks: bluebooks)
            ordered = Ports::Query::Ordering.apply(
              rows, declared.order_by, declared.null_semantics, identity: ->(row) { row[:id].to_s }
            ) { |row| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, declared.order_by.field)) }

            skipped  = declared.offset ? ordered.drop(resolve_paging_value(declared.offset.value, args).to_i) : ordered
            expected = declared.limit ? skipped.first(resolve_paging_value(declared.limit.value, args).to_i) : skipped
            actual   = asked[:rows]
            next if actual == expected

            "#{asked[:query]} #{args.inspect} answered #{actual.inspect}, but independently recomputing " \
              "order/offset/limit from #{rows.length} eligible row(s) gives #{expected.inspect}"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Resolves the declared Query for a replayed verb.
        #
        # Entity-level queries (dotted query path) return nil: they are not one aggregate's
        # own rows, which #query_eligible_rows assumes.
        #
        # @param bluebooks [Hash{String => Bluebook::Chapter}] every loaded domain
        # @param verb [String] `"Domain::Aggregate.Query"`
        # @return [Bluebook::Query, nil]
        def query_for_verb(bluebooks, verb)
          domain, aggregate_name, query_path = Naming.split_verb(verb)
          return nil unless query_path && !query_path.include?(".")

          bluebook  = bluebooks[domain]
          aggregate = bluebook&.aggregate(aggregate_name)
          aggregate&.query(query_path)
        end

        # Recomputes which of an aggregate's own stored rows a query's `wheres` admit.
        #
        # Rows get `id:` merged in because Ordering.apply's `identity:` and the real answer
        # both use it. `bluebooks:` is needed only to resolve a `/` hop clause, whose head
        # names a declared reference; without it the clause would be dug as a local path.
        #
        # @param instances [Hash{String => Hash}] `history[:instances]` or an `:instances_at`
        #   snapshot
        # @param wheres [Array<QuerySpecification::Common::WhereClause>] clauses every row
        #   must satisfy
        # @param args [Hash] the query's call args, for clauses whose value is a Symbol
        # @return [Array<Hash>] each admitted row's state, merged with its `id:`
        def query_eligible_rows(instances, domain, aggregate_name, wheres, args, bluebooks: {})
          aggregate = bluebooks[domain]&.aggregate(aggregate_name)
          prefix = "#{domain}::#{aggregate_name}#"
          instances.filter_map do |key, state|
            next unless key.start_with?(prefix)

            row = state.merge(id: key.split("#").last)
            next unless wheres.all? do |clause|
              resolved = resolve_hop_clause(instances, domain, aggregate, clause, args, bluebooks)
              held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, resolved.field))
              Ports::Query::InMemory.holds?(resolved, held, args)
            end

            row
          end
        end

        # Resolves one hop of a `/`-chained clause into a local `in` clause over the target's ids.
        #
        # Restates `Runtime::ReferenceHop#fold` over the replay snapshot, so the property never
        # checks the runtime against its own code path. A clause with no resolvable hop head
        # is returned unchanged.
        #
        # @param aggregate [Bluebook::Aggregate, nil] nil skips hop resolution
        # @return [QuerySpecification::Common::WhereClause] `clause`, or the `in` clause
        def resolve_hop_clause(instances, domain, aggregate, clause, args, bluebooks)
          return clause unless aggregate && QuerySpecification::HopPath.hop_head?(clause.field, aggregate.attributes)

          hop, rest = QuerySpecification::HopPath.next_hop(clause.field, aggregate.attributes)
          target = hop.target
          return clause unless target

          inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
          ids   = query_eligible_rows(instances, domain, target.hecks_name, [inner], args, bluebooks: bluebooks)
                  .map { |row| row[:id].to_s }.uniq

          QuerySpecification::Common::WhereClause.new(field: hop.attribute.name, op: "in", value: ids)
        end

        # Resolves a declared limit/offset: a literal, or a Symbol naming a call arg.
        def resolve_paging_value(value, args)
          value.is_a?(Symbol) ? args[value] : value
        end
      end
    end
  end
end
