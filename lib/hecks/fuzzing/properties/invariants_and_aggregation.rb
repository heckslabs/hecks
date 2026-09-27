module Hecks
  module Fuzzing
    module Properties
      # Stored-record, saga-rehydration, fan-out, and read-model-aggregation
      # properties, extended into Properties.
      module InvariantsAndAggregation
        # Every stored record — and every entity nested inside it — still
        # satisfies its own declared invariants, re-checked independently of
        # whichever call site (Admissibility#enforce_invariants) was supposed
        # to have refused a violation live.
        def stored_records_satisfy_declared_invariants(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:instances).filter_map do |key, state|
            domain_name    = key.split("::").first
            aggregate_name = key.split("::").last.split("#").first
            bluebook       = bluebooks[domain_name]
            aggregate      = bluebook&.aggregate(aggregate_name)
            next unless aggregate

            violated = aggregate.invariants.find do |invariant|
              !Bluebook::Expression::Evaluator.call(invariant.canonical, state)
            end
            next "#{key} violates #{aggregate_name}'s own declared invariant #{violated.description.inspect}" if violated

            check_piece_invariants(aggregate, state, key)
          end

          offenders.empty? || offenders.join("; ")
        end

        # A piece's own invariant, checked against every element its owner's
        # `list_of` field holds — reapplies Admissibility#check_entity_invariants'
        # own lookup against a plain Hash state rather than a live Instance.
        def check_piece_invariants(owner_construct, owner_state, key)
          owner_construct.entities.each do |entity|
            next if entity.invariants.empty?

            list_attr = owner_construct.attributes.find { |a| a.list? && a.type.to_s == entity.hecks_name }
            next unless list_attr

            Array(owner_state[list_attr.name]).each do |element|
              violated = entity.invariants.find do |invariant|
                !Bluebook::Expression::Evaluator.call(invariant.canonical, element)
              end
              if violated
                return "#{key}'s own #{entity.hecks_name} violates its declared invariant " \
                       "#{violated.description.inspect}"
              end

              nested = check_piece_invariants(entity, element, key)
              return nested if nested
            end
          end
          nil
        end

        # A saga instance's own state is one the process manager declares, and
        # its memory survives the same JSON round-trip `SagaInterpreter#checkpoint`'s
        # own `deep_copy` performs (mirrored here, a private instance method
        # with no registry to hand it).
        def sagas_rehydrate_cleanly(history)
          bluebook = history.fetch(:bluebook)
          process_managers = bluebook.process_managers.to_h { |pm| [pm.name, pm] }

          offenders = history.fetch(:saga_instances).flat_map do |pm_name, conversations|
            pm = process_managers[pm_name]

            conversations.filter_map do |correlation, instance|
              problems = []

              problems << "holds state #{instance[:state].inspect}, which #{pm_name} never declares" \
                if pm && !pm.declares_state?(instance[:state])

              rehydrated = JSON.parse(JSON.generate(instance[:memory]), symbolize_names: true)
              if rehydrated != instance[:memory]
                problems << "memory does not survive its own checkpoint round-trip " \
                            "(checkpointed #{instance[:memory].inspect}, rehydrated #{rehydrated.inspect})"
              end

              next if problems.empty?

              "#{pm_name}##{correlation.inspect}: #{problems.join(' and ')}"
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # A `for_each` policy dispatches exactly once per row its declared query
        # answers, checked against `Replay.expected_fan_out_rows`'s independent
        # computation. `expected_row_ids` is `nil`, not `[]`, when `policy.where`
        # never held — no dispatch is the claim then, not "dispatched to zero rows."
        def fanout_dispatches_once_per_matching_row(history)
          offenders = history.fetch(:fan_outs).filter_map do |finding|
            expected = finding[:expected_row_ids]
            actual   = finding[:actual_row_ids].sort

            if expected.nil?
              next if actual.empty?

              next "#{finding[:policy]} on #{finding[:on]}: where did not hold, but dispatched to #{actual.inspect}"
            end

            next if actual == expected

            "#{finding[:policy]} on #{finding[:on]}: for_each answered #{expected.inspect}, " \
              "but the reaction log shows dispatches to #{actual.inspect}"
          end

          offenders.empty? || offenders.join("; ")
        end

        # A `count`/`median` report's reduced scalar matches the same reduction
        # done independently over the same eligible rows, reusing FieldPath.dig
        # and InMemory.comparable/.holds? — the same calls the interpreter
        # itself makes, so this oracle can't drift from what a field read or a
        # `where` clause means without the interpreter drifting identically.
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        def aggregation_matches_recompute(history)
          bluebook = history.fetch(:bluebook)

          offenders = history.fetch(:queries).filter_map do |asked|
            next if asked[:error]

            domain, name = asked[:query].to_s.split(".", 2)
            next unless name && domain == bluebook.name

            model = bluebook.read_model(name)
            next unless model && (model.count? || model.median_field)

            reduced_head = model.aggregate_heads.find { |head| head[:many] }
            next unless reduced_head

            rows = eligible_rows(bluebook, asked.fetch(:instances_at), domain, model, reduced_head, asked[:args] || {})
            expected = model.count? ? rows.length : recompute_median(rows, model.median_field)
            actual = asked[:rows]&.first&.dig(reduced_head[:as])
            next if actual == expected

            "#{asked[:query]} #{asked[:args].inspect} answered #{actual.inspect} for #{reduced_head[:as]}, " \
              "but recomputing independently from #{rows.length} eligible row(s) gives #{expected.inspect}"
          end

          offenders.empty? || offenders.join("; ")
        end

        # aggregation_matches_recompute's own shape, extended from reducing a
        # many-side head to a scalar to nesting it (ADR 0061, decision D1): a
        # group_by leaf holds one row, so two eligible rows sharing a full key
        # path not covering identity means the ask must have refused.
        def group_by_matches_recompute(history)
          bluebook = history.fetch(:bluebook)

          offenders = history.fetch(:queries).filter_map do |asked|
            domain, name = asked[:query].to_s.split(".", 2)
            next unless name && domain == bluebook.name

            model = bluebook.read_model(name)
            next unless model&.group_by&.any?

            grouped_head = model.aggregate_heads.find { |head| head[:many] }
            next unless grouped_head

            group_by_offense(bluebook, asked, model, grouped_head)
          end

          offenders.empty? || offenders.join("; ")
        end

        # Judges one `group_by` ask against the rows it was eligible to see:
        # refused exactly when two of them share a checked key path, and
        # otherwise nested exactly as `nest_rows` nests them.
        def group_by_offense(bluebook, asked, model, grouped_head)
          rows = eligible_rows(bluebook, asked.fetch(:instances_at), bluebook.name, model, grouped_head, asked[:args] || {})
          materialized = rows.map { |state| Runtime::Value.materialize_unwrapped(state) }
          shared = shared_key_paths(materialized, model.group_by_fields)
          checked = !model.groups_by_identity?(bluebook.aggregate(grouped_head[:aggregate]))
          return collision_offense(asked, model.group_by_fields, shared.length, checked) if shared.any?
          return nil if asked[:error]
          return nil if asked[:rows]&.first&.dig(grouped_head[:as]) == nest_rows(materialized, model.group_by_fields)

          "#{asked[:query]} #{asked[:args].inspect} answered a #{grouped_head[:as]} grouping that disagrees " \
            "with independently nesting group_by #{model.group_by_fields.inspect} over #{rows.length} " \
            "eligible row(s)"
        end

        # Judges an ask whose eligible rows share at least one full key path:
        # a checked key path must have refused, and an identity-covering one
        # cannot be shared by rows that hold their identity.
        def collision_offense(asked, fields, shared, checked)
          return nil if checked && asked[:error]

          "#{asked[:query]} #{asked[:args].inspect} #{checked ? 'answered' : 'reached'}, but #{shared} key " \
            "path(s) of group_by #{fields.inspect} are shared by more than one eligible row, " \
            "#{checked ? 'so the ask must refuse' : 'though they cover the identity'}"
        end

        # Every full `group_by` key path more than one row reaches, found by
        # tallying each row's tuple of grouped values, with no nesting at all.
        def shared_key_paths(rows, fields)
          rows.map { |row| fields.map { |field| row[field] } }.tally.select { |_, count| count > 1 }.keys
        end

        # One level of nesting per `group_by` field in declared order; the leaf
        # is the row with every grouped field stripped. Called only when no key
        # path is shared (`shared_key_paths` rules that out), so each leaf holds
        # exactly one row; a second row raises rather than being picked over.
        def nest_rows(rows, fields)
          field, *rest = fields
          rows.group_by { |row| row[field] }.transform_values do |group|
            stripped = group.map { |row| row.reject { |key, _| key == field } }
            next nest_rows(stripped, rest) unless rest.empty?
            raise ArgumentError, "nest_rows reached a key path #{stripped.length} rows share" unless stripped.length == 1

            stripped[0]
          end
        end

        # The eligible rows a `count`/`median` head reduces: every instance of
        # the reduced head's own aggregate, FK-matched against the report's root
        # reference (if any), then narrowed by the report's own `where` clauses.
        def eligible_rows(bluebook, instances, domain, model, reduced_head, args)
          aggregate = bluebook.aggregate(reduced_head[:aggregate])
          prefix = "#{domain}::#{reduced_head[:aggregate]}#"
          # `id:` merged in, the same shape every live head row carries —
          # count/median never read it, but group_by's own nesting does.
          rows = instances.filter_map { |key, state| state.merge(id: key.split("#").last) if key.start_with?(prefix) }

          if model.reference_target
            reference_id = args[model.reference_name].to_s
            fk_fields = aggregate.attributes.select do |attribute|
              attribute.reference? && attribute.type.target_name == model.reference_target.to_s
            end.map(&:name)

            rows = rows.select { |state| fk_fields.any? { |field| state[field].to_s == reference_id } }
          end

          rows.select do |state|
            model.wheres.all? do |clause|
              held = Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, clause.field))
              Ports::Query::InMemory.holds?(clause, held, args)
            end
          end
        end

        # ReadModelInterpreter#median's own definition, reproduced: the true
        # middle for an odd count, the average of the two middles for an even
        # count, `nil` for empty — never zero, so "nothing" isn't "zero."
        def recompute_median(rows, field)
          values = rows.map { |state| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, field)) }
                       .compact.sort
          return nil if values.empty?

          middle = values.length / 2
          values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
        end
      end
    end
  end
end
