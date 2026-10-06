require "json"
require_relative "aggregation_recompute"
require_relative "group_by_recompute"
require_relative "piece_invariants"

module Hecks
  module Fuzzing
    module Properties
      # Stored-record, saga-rehydration, fan-out, and read-model-aggregation
      # properties, extended into Properties.
      module InvariantsAndAggregation
        include AggregationRecompute
        include GroupByRecompute
        include PieceInvariants

        # Every stored record — and every entity nested inside it — still
        # satisfies its own declared invariants, re-checked independently of
        # whichever call site (Admissibility#enforce_invariants) was supposed
        # to have refused a violation live.
        def stored_records_satisfy_declared_invariants(history)
          bluebooks = history.fetch(:bluebooks)
          offenders = history.fetch(:instances).filter_map { |key, state| stored_record_offense(bluebooks, key, state) }
          offenders.empty? || offenders.join("; ")
        end

        # A saga instance's own state is one the process manager declares, and
        # its memory survives the same JSON round-trip `SagaInterpreter#checkpoint`'s
        # own `deep_copy` performs (mirrored here, a private instance method
        # with no registry to hand it).
        def sagas_rehydrate_cleanly(history)
          process_managers = history.fetch(:bluebook).process_managers.to_h { |pm| [pm.name, pm] }

          offenders = history.fetch(:saga_instances).flat_map do |pm_name, conversations|
            conversations.filter_map do |correlation, instance|
              saga_offense(pm_name, process_managers[pm_name], correlation, instance)
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # The message for one saga conversation that breaks, or nil.
        def saga_offense(pm_name, manager, correlation, instance)
          problems = saga_problems(pm_name, manager, instance)
          "#{pm_name}##{correlation.inspect}: #{problems.join(" and ")}" unless problems.empty?
        end

        def saga_problems(pm_name, manager, instance)
          problems = []
          problems << "holds state #{instance[:state].inspect}, which #{pm_name} never declares" \
            if manager && !manager.declares_state?(instance[:state])

          rehydrated = JSON.parse(JSON.generate(instance[:memory]), symbolize_names: true)
          if rehydrated != instance[:memory]
            problems << "memory does not survive its own checkpoint round-trip " \
                        "(checkpointed #{instance[:memory].inspect}, rehydrated #{rehydrated.inspect})"
          end
          problems
        end

        # A `for_each` policy dispatches exactly once per row its declared query
        # answers, checked against `Replay.expected_fan_out_rows`'s independent
        # computation. `expected_row_ids` is `nil`, not `[]`, when `policy.where`
        # never held — no dispatch is the claim then, not "dispatched to zero rows."
        def fanout_dispatches_once_per_matching_row(history)
          offenders = history.fetch(:fan_outs).filter_map { |finding| fan_out_offense(finding) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one fan-out whose dispatches differ from the expectation, or nil.
        def fan_out_offense(finding)
          expected = finding[:expected_row_ids]
          actual   = finding[:actual_row_ids].sort
          return unexpected_dispatch_offense(finding, actual) if expected.nil?
          return if actual == expected

          "#{finding[:policy]} on #{finding[:on]}: for_each answered #{expected.inspect}, " \
            "but the reaction log shows dispatches to #{actual.inspect}"
        end

        def unexpected_dispatch_offense(finding, actual)
          return if actual.empty?

          "#{finding[:policy]} on #{finding[:on]}: where did not hold, but dispatched to #{actual.inspect}"
        end

        # A `count`/`median` report's reduced scalar matches the same reduction
        # done independently over the same eligible rows, reusing FieldPath.dig
        # and InMemory.comparable/.holds? — the same calls the interpreter
        # itself makes, so this oracle can't drift from what a field read or a
        # `where` clause means without the interpreter drifting identically.
        def aggregation_matches_recompute(history)
          bluebook = history.fetch(:bluebook)
          offenders = history.fetch(:queries).filter_map { |asked| aggregation_offense(bluebook, asked) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one reducing ask whose answer disagrees with the recomputation, or nil.
        def aggregation_offense(bluebook, asked)
          return if asked[:error]

          model = asked_read_model(bluebook, asked)
          return unless model&.reducing?

          reduced_head = many_head(model)
          reduced_head && reduction_offense(bluebook, asked, model, reduced_head)
        end

        def reduction_offense(bluebook, asked, model, reduced_head)
          rows = eligible_rows(bluebook, asked.fetch(:instances_at), model, reduced_head, asked[:args] || {})
          expected = recompute_reduction(model, rows)
          actual = asked[:rows]&.first&.dig(reduced_head[:as])
          return if actual == expected

          "#{asked[:query]} #{asked[:args].inspect} answered #{actual.inspect} for #{reduced_head[:as]}, " \
            "but recomputing independently from #{rows.length} eligible row(s) gives #{expected.inspect}"
        end

        # aggregation_matches_recompute's own shape, extended from reducing a
        # many-side head to a scalar to nesting it (ADR 0061, decision D1): a
        # group_by leaf holds one row, so two eligible rows sharing a full key
        # path not covering identity means the ask must have refused.
        def group_by_matches_recompute(history)
          bluebook = history.fetch(:bluebook)
          offenders = history.fetch(:queries).filter_map { |asked| group_by_ask_offense(bluebook, asked) }
          offenders.empty? || offenders.join("; ")
        end

        def group_by_ask_offense(bluebook, asked)
          model = asked_read_model(bluebook, asked)
          return unless model&.group_by&.any?

          grouped_head = many_head(model)
          grouped_head && group_by_offense(bluebook, asked, model, grouped_head)
        end
      end
    end
  end
end
