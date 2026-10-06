require_relative "query_rows"

module Hecks
  module Fuzzing
    module Properties
      # Properties that check a query's answer against an independent recomputation.
      module Querying
        include QueryRows

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
          offenders = history.fetch(:queries).filter_map { |asked| reference_offense(asked) }
          offenders.empty? || offenders.join("; ")
        end

        # Whether a replayed ask names an aggregate query (`Domain::Aggregate.Query`) rather than
        # a read model.
        def namespaced_query?(asked) = asked[:query].is_a?(String) && asked[:query].include?("::")

        # The message for one ask whose native and reference answers disagree, or nil.
        def reference_offense(asked)
          return unless namespaced_query?(asked)

          native_refused    = asked.key?(:error)
          reference_refused = asked.key?(:reference_error)
          return refusal_divergence(asked, native_refused, reference_refused) if native_refused != reference_refused
          return if native_refused || asked[:rows] == asked[:reference_rows]

          "#{asked[:query]} #{asked[:args].inspect} answered #{asked[:rows].inspect} " \
            "natively but #{asked[:reference_rows].inspect} through the reference interpreter"
        end

        def refusal_divergence(asked, native_refused, reference_refused)
          "#{asked[:query]} #{asked[:args].inspect} — native " \
            "#{native_refused ? "refused (#{asked[:error]})" : "answered"}, " \
            "but the reference interpreter #{reference_refused ? "refused (#{asked[:reference_error]})" : "answered"} — " \
            "a refusal-shaped divergence, not just a differing row set"
        end

        # Recomputes order/offset/limit from `history[:instances]` and compares it with the
        # real answer of every paged query (`order_by` with `offset` or `limit`).
        #
        # Ordering reuses `Ports::Query::Ordering.apply` so "in order" cannot drift from the
        # interpreter; only the offset-then-limit slice is restated. Comparing the interpreter's
        # native and reference paths instead could share one bug.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true, or a message naming each mismatching query
        def paging_offset_partitions_correctly(history)
          bluebooks = history.fetch(:bluebooks)
          offenders = history.fetch(:queries).filter_map { |asked| paging_offense(bluebooks, asked) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one paged ask whose answer differs from the recomputed page, or nil.
        def paging_offense(bluebooks, asked)
          declared = paged_query(bluebooks, asked)
          return unless declared

          args = normalized_args(bluebooks, asked, declared)
          rows = eligible_rows_for(bluebooks, asked, declared, args)
          expected = expected_page(rows, declared, args)
          return if asked[:rows] == expected

          "#{asked[:query]} #{args.inspect} answered #{asked[:rows].inspect}, but independently recomputing " \
            "order/offset/limit from #{rows.length} eligible row(s) gives #{expected.inspect}"
        end

        # The declared query of an answered ask that pages (`order_by` with offset or limit).
        def paged_query(bluebooks, asked)
          return if asked[:error] || !namespaced_query?(asked)

          declared = query_for_verb(bluebooks, asked[:query])
          declared if declared&.order_by && (declared.offset || declared.limit)
        end

        # The stored rows the asked query's `wheres` admit, in the snapshot the ask ran against.
        def eligible_rows_for(bluebooks, asked, declared, args)
          domain, aggregate_name, = Naming.split_verb(asked[:query])
          snapshot = Snapshot.new(asked.fetch(:instances_at), domain, bluebooks)
          query_eligible_rows(snapshot, aggregate_name, declared.wheres, args)
        end

        def normalized_args(bluebooks, asked, declared)
          domain, aggregate_name, = Naming.split_verb(asked[:query])
          aggregate = bluebooks[domain]&.aggregate(aggregate_name)
          normalize_query_args(aggregate, declared, asked[:args] || {})
        end

        # The rows `declared` should answer: ordered, then offset, then limited.
        def expected_page(rows, declared, args)
          ordered = ordered_rows(rows, declared)
          skipped = declared.offset ? ordered.drop(resolve_paging_value(declared.offset.value, args).to_i) : ordered
          declared.limit ? skipped.first(resolve_paging_value(declared.limit.value, args).to_i) : skipped
        end

        def ordered_rows(rows, declared)
          Ports::Query::Ordering.apply(
            rows, declared.order_by, declared.null_semantics, identity: ->(row) { row[:id].to_s }
          ) { |row| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, declared.order_by.field)) }
        end

        # Real dispatch normalizes a query's own declared arguments
        # (`QueryInterpreter#normalize_args`) before ever evaluating a where clause,
        # filling a composite argument's own declared defaults along the way
        # (`Value.for_attribute` -> `Value.build`). The language's own ambiguous-
        # comparison guard (`refuse_ambiguous_comparison!`) rules out comparing most
        # multi-field value objects whole, but a single-attribute one (still eligible,
        # since it is never ambiguous) can still arrive with that one field omitted —
        # recomputing eligibility against the raw fuzzed args instead of this normalized
        # copy would then disagree with real dispatch — the same false-divergence shape
        # `build_guard_check` guards against for the guard check. `Runtime::QueryInterpreter.
        # new(nil)` is safe: `normalize_args` never reads the registry it would otherwise need.
        def normalize_query_args(aggregate, declared, args)
          return args unless aggregate

          Runtime::QueryInterpreter.new(nil).send(:normalize_args, aggregate, declared, args)
        rescue StandardError
          args
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

        # Resolves a declared limit/offset: a literal, or a Symbol naming a call arg.
        def resolve_paging_value(value, args)
          value.is_a?(Symbol) ? args[value] : value
        end
      end
    end
  end
end
