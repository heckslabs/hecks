module Hecks
  module Fuzzing
    module Properties
      # Stored-record, saga-rehydration, fan-out, and read-model-aggregation
      # properties: every stored record still satisfies its own declared
      # invariants, a saga rehydrates cleanly from a checkpoint, a policy's
      # own for_each/where fans out exactly once per matching row, and a
      # read model's count/median/group_by answers match an independent
      # recomputation.

      # Holds stored_records_satisfy_declared_invariants, sagas_rehydrate_cleanly,
      # fanout_dispatches_once_per_matching_row, aggregation_matches_recompute,
      # and group_by_matches_recompute, plus the recomputation helpers
      # (#check_piece_invariants, #eligible_rows, #nest_rows,
      # #recompute_median) each leans on.
      module InvariantsAndAggregation
        # EVERY STORED RECORD STILL SATISFIES ITS OWN AGGREGATE'S DECLARED
        # INVARIANTS — Admissibility#enforce_invariants (command_rules/
        # admissibility.rb) checks these AFTER every command's mutations,
        # BEFORE save, the same point `ensures` is checked. Nothing until
        # now re-checked a record AFTER a whole replay finished, independent
        # of whichever call site was supposed to have refused a violation
        # in the first place — a record failing its own declared invariant
        # here is proof a violating write landed anyway: the call site
        # stopped calling enforce_invariants, or some other path (a
        # translation, a backfill) wrote around it entirely.
        #
        # `history[:instances]` entries are already plain, symbol-keyed
        # state Hashes (Replay.call's own `record.state`) — called against
        # Evaluator.call the SAME way ValueObject::Builder#build already
        # does for a VO's own invariants (value/coercion.rb), no GuardState
        # wrapper needed the way enforce_invariants' own LIVE call uses one
        # (GuardState exists for `parent.`/projected-field dereferencing
        # mid-dispatch; a stored record's own scalar fields need none of
        # that to re-check a same-aggregate invariant against itself).
        #
        # Real target: Account's own `invariant("the balance never goes
        # negative") { balance.cents >= 0 }`.
        #
        # Entity#invariants (round 7) closes here too, not for free —
        # `stored_records_satisfy_declared_invariants` only ever checked
        # the AGGREGATE's own flat state; a piece's own invariant is
        # checked against every ELEMENT of a `list_of` field, a genuinely
        # different walk `check_piece_invariants` below makes,
        # independently of `Admissibility#check_entity_invariants` (the
        # live enforcement path this property exists to catch drifting
        # from) — same reasoning `stored_records_satisfy_declared_
        # invariants`' own top-level check already applies one level up.
        #
        # Real target: SafeDepositBox's own Visit — `invariant("a written
        # note is not blank") { !note || !note.text.to_s.empty? }`.
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

        # A PIECE'S OWN INVARIANT, checked against every element a
        # `list_of` field holds — the SAME lookup `Admissibility#
        # check_entity_invariants` makes (`owner.attributes.find { |a|
        # a.list? && a.type.to_s == entity.hecks_name }`), independently
        # reapplied here against a STORED record's own plain Hash state
        # rather than a live `Instance`.
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

        # A SAGA INSTANCE'S OWN CHECKPOINT SURVIVES BEING WRITTEN AND READ
        # BACK — the durability contract `SagaInterpreter#checkpoint` makes
        # (`state:` plus a `deep_copy`d `memory:`, handed to whatever
        # adapter answers `save_saga`) and `Registry#rehydrate_sagas!`
        # promises to restore on the next boot (`each_saga` yielding
        # `[pm, correlation, state, memory]` back into `saga_instances`).
        # `Replay` captures the LIVE store already materialised the same
        # way `checkpoint` itself does (`Value.materialize`, not raw
        # `Runtime::Value`s — see its own comment); this property pushes
        # that captured memory through the SAME `JSON.generate` then
        # `JSON.parse(symbolize_names: true)` round-trip `checkpoint`'s own
        # `deep_copy` performs (mirrored here rather than called — a
        # private instance method with no registry to hand it) and checks
        # it comes back byte-identical. A memory holding anything that
        # round-trip cannot carry faithfully — a bare Symbol leaf, a
        # non-JSON type a future field introduces — is corruption the
        # durable path would introduce on a REAL restart, caught here
        # without needing one.
        #
        # `declares_state?` (Behaviour::ProcessManager) is the other half:
        # a live or rehydrated instance sitting in a state the procedure
        # never declares is the saga-durability twin of
        # `lifecycle_values_are_declared` above.
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

        # A `for_each` POLICY DISPATCHES EXACTLY ONCE PER ROW ITS DECLARED
        # QUERY ANSWERS — never once for the triggering event regardless of
        # row count, never skipping a matched row, never firing on a row a
        # concurrent mutation only made match AFTER the fact. `Replay`
        # computes the expected row-id set INDEPENDENTLY, at the same
        # instant the real dispatch runs (`Replay.expected_fan_out_rows`,
        # the query oracle's own shape aimed at fan-out: two engines
        # compared, never one graded against itself), and records it
        # beside what the reaction log actually shows. `expected_row_ids`
        # is `nil`, not `[]`, when `policy.where` did not hold — no
        # dispatch is the claim then, not "dispatched to zero rows," and a
        # policy that dispatched anyway despite a failing guard is as real
        # a finding as a row it skipped.
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

        # A `count`/`median` REPORT'S REDUCED SCALAR MATCHES THE SAME
        # REDUCTION DONE INDEPENDENTLY, over the SAME eligible rows —
        # `ReadModelInterpreter#project`'s own FK-join (root first, then
        # each many-side head matched against it) and `#median` (odd →
        # the true middle, even → the average of the two middles as a
        # Float, empty → `nil`; `count` is the filtered length, empty →
        # `0`), reproduced here in plain Ruby against `history[:instances]`
        # rather than a live registry — `FieldPath.dig` +
        # `Ports::Query::InMemory.comparable`/`.holds?` are the SAME two
        # calls the interpreter itself makes to read a field and judge a
        # `where`, called here rather than re-derived, so this oracle
        # cannot drift from what "read a field" or "a clause holds" mean
        # without the interpreter drifting the identical way.
        #
        # Only a report whose `:query` is answered by the SAME bluebook
        # `history[:bluebook]` carries (the bare `Domain.report_name`
        # form, `domain == bluebook.name`) is checked — the same "only
        # what we have the grammar for" scope `lifecycle_values_are_declared`
        # already takes for a multi-domain replay.
        # See the comment above: a closed chain of eligibility guards
        # ("only a report answered by this bluebook, only a count/median
        # report, only one with a reduced many-side head") each gating the
        # next, ending in one independent recomputation compared against
        # the live answer. The guards are what make this oracle SCOPED
        # correctly, not incidental complexity — narrower than "every
        # branch reads as its own precondition."
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

        # `aggregation_matches_recompute`'s own shape, extended from
        # reducing a many-side head to a scalar (count/median) to NESTING
        # it — `ReadModelInterpreter#group_by_target`/`#nest`, reproduced
        # here in plain Ruby against `history[:instances]` the same way
        # `eligible_rows` already reproduces the FK-join and `where`
        # narrowing count/median share. `Value.materialize_unwrapped` is
        # the SAME call `#project` makes before nesting (a single-field
        # value object recurses to its bare scalar — a real grouping key
        # has to BE one) — called here rather than re-derived, so this
        # oracle cannot drift from what "the group key" means without the
        # interpreter drifting the identical way.
        #
        # Real target: AccountsByKind (`group_by :kind, :number`,
        # rootless — always generator-eligible with `{}` args).
        # Same closed eligibility-guard chain as aggregation_matches_
        # recompute just above (see its own comment) — group_by in place
        # of count/median, nest_rows in place of recompute_median.
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        def group_by_matches_recompute(history)
          bluebook = history.fetch(:bluebook)

          offenders = history.fetch(:queries).filter_map do |asked|
            next if asked[:error]

            domain, name = asked[:query].to_s.split(".", 2)
            next unless name && domain == bluebook.name

            model = bluebook.read_model(name)
            next unless model&.group_by&.any?

            grouped_head = model.aggregate_heads.find { |head| head[:many] }
            next unless grouped_head

            rows = eligible_rows(bluebook, asked.fetch(:instances_at), domain, model, grouped_head, asked[:args] || {})
            materialized = rows.map { |state| Runtime::Value.materialize_unwrapped(state) }
            expected = nest_rows(materialized, model.group_by_fields)
            actual = asked[:rows]&.first&.dig(grouped_head[:as])
            next if actual == expected

            "#{asked[:query]} #{asked[:args].inspect} answered a #{grouped_head[:as]} grouping that disagrees " \
              "with independently nesting group_by #{model.group_by_fields.inspect} over #{rows.length} " \
              "eligible row(s)"
          end

          offenders.empty? || offenders.join("; ")
        end

        # `ReadModelInterpreter#nest`, byte for byte: one level of nesting
        # per `group_by` field in declared order, leaf is the row with
        # every grouped field stripped (already spent, as the keys that
        # reached it).
        def nest_rows(rows, fields)
          field, *rest = fields
          rows.group_by { |row| row[field] }.transform_values do |group|
            stripped = group.map { |row| row.reject { |key, _| key == field } }
            rest.empty? ? stripped.first : nest_rows(stripped, rest)
          end
        end

        # THE ELIGIBLE ROWS a `count`/`median` head reduces — every
        # instance of the reduced head's own aggregate, FK-matched against
        # the report's root reference (if it has one; a rootless report has
        # none to match) exactly the way `ReadModelInterpreter#reference_fields`
        # finds the matching attribute, then narrowed by the report's own
        # `where` clauses via the SAME `InMemory.holds?` the interpreter's
        # `execute` calls.
        def eligible_rows(bluebook, instances, domain, model, reduced_head, args)
          aggregate = bluebook.aggregate(reduced_head[:aggregate])
          prefix = "#{domain}::#{reduced_head[:aggregate]}#"
          # `id:` MERGED IN, the same `record.to_h` (`@state.merge(id:
          # @id)`) every live head row carries — count/median never read
          # it, but group_by_matches_recompute's own independent nesting
          # does, the same way ReadModelInterpreter#row(record) = record.
          # to_h does for the live path it's checking against.
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

        # `ReadModelInterpreter#median`'s own definition, reproduced byte
        # for byte: odd count → the true middle value, sorted; even count
        # → the average of the two middle values, as a Float; empty → nil,
        # never zero, so a caller cannot mistake "nothing to average" for
        # "averaged to zero."
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
