module Hecks
  module Fuzzing
    module Properties
      # Query-answering properties: a query's own answer matches a from-
      # scratch reference recomputation, paging partitions its rows the same
      # way, and the shared query/paging helpers both lean on.

      # Holds query_answers_match_reference and paging_offset_partitions_correctly,
      # plus the shared verb-resolution and eligible-rows/hop-chain helpers
      # (#query_for_verb, #query_eligible_rows, #resolve_hop_clause) other
      # property modules in this directory also call.
      module Querying
        # THE QUERY ORACLE — differential testing within the one runtime,
        # the shape the retired cross-runtime harness should always have
        # been. Every generated ask was answered twice at the same instant
        # (Replay records both): once through whatever the aggregate is
        # actually bound to (Memory's native hook is Ports::Query::InMemory;
        # a SQL binding would compile it), once through the reference
        # interpreter's own evaluation. The two are separate, live
        # implementations of the same comparator vocabulary, and they have
        # drifted before — an adapter that ACCEPTS what the reference says
        # matches nothing, or orders what it refuses to order, shows up
        # here as a finding no self-referential adapter spec could see.
        # M23 — `Replay` now runs the native and reference engines
        # INDEPENDENTLY (each in its own begin/rescue — see that file's own
        # comment at the capture site), so this property can tell apart what
        # used to be indistinguishable: "both engines refused" (fine — the
        # ask was genuinely bad, nothing to compare) from "one refused and
        # the other did not" (a real divergence — the two engines disagree
        # about whether the ask was even VALID, never mind what it answers).
        # `native_refused`/`reference_refused` are read by KEY PRESENCE, not
        # truthiness — `Replay` only ever adds `:error`/`:reference_error`
        # to an entry when that side actually raised, so an absent key is an
        # unambiguous "this side answered." A read-model ask (no reference
        # twin attempted at all, `asked[:query]` without "::") is skipped
        # entirely, same as always — there is no second engine to disagree
        # with.
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

        # THE SAME "TWO ENGINES, COMPARED" SHAPE query_answers_match_reference
        # already uses, aimed squarely at Query#options' offset/limit pair —
        # but recomputed from history[:instances] directly, a THIRD,
        # independent computation, rather than comparing QueryInterpreter's
        # own native and reference paths against each other (which could
        # share the identical bug neither implementation happened to hit —
        # see #4's own fix, which touched BOTH #interpret and
        # #reference_interpret at once). `order_by` declared alongside
        # `offset` or `limit` names a genuinely paged query. Ports::Query::
        # Ordering.apply is the SAME engine QueryInterpreter#ordered calls,
        # reused here rather than re-derived, so this oracle cannot drift
        # from what "in order" means without the interpreter drifting the
        # identical way — only the offset-then-limit .drop/.first slice
        # (#4's own fix) is independently reproduced, in plain Ruby.
        #
        # Real target: ATMCard.ByFee (`limit 3; offset 1`).
        #
        # One independent recomputation, order-dependent by construction
        # (declared query -> eligible rows -> ordered -> offset-sliced ->
        # limit-sliced -> compared against the real answer, per the doc
        # comment above): splitting it would scatter `rows`/`ordered`/
        # `skipped`/`expected` across method boundaries as params/returns
        # for a sequence that's only ever computed once, in this order.
        # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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

        # THE DECLARED Query ITSELF, resolved from a replayed verb — the
        # same shape #command_for_verb resolves a command by, one
        # construct over. Entity-level queries (a dotted query_path) are
        # out of scope here — paging on an entity's own list has no real
        # corpus site yet, and the "one many-side head, one aggregate,
        # no FK-join" shape #query_eligible_rows assumes doesn't hold for
        # one.
        def query_for_verb(bluebooks, verb)
          domain, aggregate_name, query_path = Naming.split_verb(verb)
          return nil unless query_path && !query_path.include?(".")

          bluebook  = bluebooks[domain]
          aggregate = bluebook&.aggregate(aggregate_name)
          aggregate&.query(query_path)
        end

        # A QUERY'S OWN ROWS — unlike #eligible_rows (a ReadModel's
        # reduced/grouped many-side head, possibly FK-joined against a
        # root), a Query always asks about its OWN owning aggregate
        # directly ; no join, no reference_target. `id:` merged in the
        # same way #eligible_rows' own rows are, since a stable sort
        # (Ordering.apply's own `identity:`) and the real answer's own
        # `record.state.merge(id: record.id)` both need it.
        # `bluebooks:` — needed ONLY to recognise and resolve a `/` HOP
        # clause (`engagement/client/status`, hop_chain.bluebook's own
        # PricedAboveViaEngagement): a hop's head names one of the OWNING
        # aggregate's declared references, and only the declaration graph
        # can say which attribute that is and which aggregate it targets.
        # A local clause never consults it. Latent gap this closed, found
        # by the fuzzer itself the first time a generated sequence ever
        # built a full hop chain AND had its paged query answer a row
        # (seed 1, the moment scalar_value_objects.bluebook joined the
        # fixtures corpus and shifted every seeded draw): the recompute
        # dug `engagement/client/status` as a LOCAL dotted path, found
        # nil, and declared every genuinely-eligible row ineligible — a
        # false property violation against a correct runtime answer,
        # reproducible on an untouched main with this same 4-step script.
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

        # `Runtime::ReferenceHop#fold`, independently restated over the
        # replay's own `:instances_at` snapshot instead of live
        # repositories — the same shape every other recompute in this
        # file takes (never the runtime's own code path, or the property
        # would be checking the runtime against itself). One hop peels
        # off the head (`HopPath.next_hop`, the identical one-step
        # primitive the live fold uses), the inner clause recurses
        # through `query_eligible_rows` against the TARGET's own
        # snapshot rows (so a multi-hop tail resolves hop by hop, exactly
        # as the live path's own recursion does), and the ids that
        # answered fold back as the same local `in` membership clause the
        # live fold builds. A clause with no `/`, or one whose head this
        # aggregate's declarations cannot resolve, passes through
        # untouched and evaluates locally as it always did.
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

        # `QueryInterpreter#resolve_query_value`, reproduced: a declared
        # limit/offset is either a literal or a Symbol naming an argument
        # the caller supplied.
        def resolve_paging_value(value, args)
          value.is_a?(Symbol) ? args[value] : value
        end
      end
    end
  end
end
