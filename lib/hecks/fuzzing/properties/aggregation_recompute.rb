module Hecks
  module Fuzzing
    module Properties
      # Independent recomputations of read-model reductions and `group_by` nestings, for
      # `InvariantsAndAggregation` to compare against what a query actually answered.
      module AggregationRecompute
        # The read model a recorded ask named, when it belongs to `bluebook`.
        def asked_read_model(bluebook, asked)
          domain, name = asked[:query].to_s.split(".", 2)
          bluebook.read_model(name) if name && domain == bluebook.name
        end

        # The head a read model reduces or groups: the one declared `many`.
        def many_head(model) = model.aggregate_heads.find { |head| head[:many] }

        # ADR 0078's siblings of `count`/`median`, each an independent fold over the same
        # eligible rows — never reusing ReadModelInterpreter#reduce's own arithmetic, only the
        # shared field-reading primitives `recompute_median` already relied on.
        def recompute_reduction(model, rows)
          return rows.length if model.count?
          return recompute_median(rows, model.median_field) if model.median_field
          return recompute_values(rows, model.sum_field).sum if model.sum_field
          return recompute_avg(rows, model.avg_field) if model.avg_field

          recompute_extremum_or_flag(model, rows)
        end

        # The `min`, `max`, `percentile`, `any` and `all` folds of `recompute_reduction`.
        def recompute_extremum_or_flag(model, rows)
          return recompute_values(rows, model.min_field).min if model.min_field
          return recompute_values(rows, model.max_field).max if model.max_field

          recompute_percentile_or_flag(model, rows)
        end

        # The `percentile`, `any` and `all` folds of `recompute_reduction`.
        def recompute_percentile_or_flag(model, rows)
          return recompute_percentile(rows, model.percentile_field, model.percentile_at) if model.percentile_field
          return recompute_values(rows, model.any_field).any? if model.any_field

          recompute_values(rows, model.all_field).all?
        end

        def recompute_values(rows, field)
          rows.map { |state| comparable_field(state, field) }.compact
        end

        # A field's value as the interpreter itself compares it.
        def comparable_field(state, field)
          Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(state, field))
        end

        def recompute_avg(rows, field)
          values = recompute_values(rows, field)
          values.empty? ? nil : values.sum.to_f / values.length
        end

        # Same linear-interpolation formula as `ReadModelInterpreter#percentile`, written
        # independently here rather than called, for the same reason `recompute_median`
        # already is: an oracle that calls the interpreter's own fold agrees with a bug in it
        # by construction (ADR 0061's `nest_rows` lesson).
        def recompute_percentile(rows, field, at)
          values = recompute_values(rows, field).sort
          return nil if values.empty?

          interpolate(values, at * (values.length - 1))
        end

        def interpolate(values, position)
          lower = position.floor
          fraction = position - lower
          fraction.zero? ? values[lower] : values[lower] + (fraction * (values[lower + 1] - values[lower]))
        end

        # ReadModelInterpreter#median's own definition, reproduced: the true
        # middle for an odd count, the average of the two middles for an even
        # count, `nil` for empty — never zero, so "nothing" isn't "zero."
        def recompute_median(rows, field)
          values = rows.map { |state| comparable_field(state, field) }.compact.sort
          return nil if values.empty?

          middle = values.length / 2
          values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
        end

        # The eligible rows a `count`/`median` head reduces: every instance of
        # the reduced head's own aggregate, FK-matched against the report's root
        # reference (if any), then narrowed by the report's own `where` clauses.
        def eligible_rows(bluebook, instances, model, reduced_head, args)
          prefix = "#{bluebook.name}::#{reduced_head[:aggregate]}#"
          # `id:` merged in, the same shape every live head row carries —
          # count/median never read it, but group_by's own nesting does.
          rows = instances.filter_map { |key, state| state.merge(id: key.split("#").last) if key.start_with?(prefix) }
          rows = rows_for_reference(rows, bluebook.aggregate(reduced_head[:aggregate]), model, args) if model.reference_target

          rows.select { |state| satisfies_wheres?(model, state, args) }
        end

        # The rows whose foreign key holds the root reference the ask named.
        def rows_for_reference(rows, aggregate, model, args)
          reference_id = args[model.reference_name].to_s
          fk_fields = foreign_key_fields(aggregate, model)
          rows.select { |state| fk_fields.any? { |field| state[field].to_s == reference_id } }
        end

        # The names of `aggregate`'s attributes referencing the read model's root.
        def foreign_key_fields(aggregate, model)
          aggregate.attributes.select do |attribute|
            attribute.reference? && attribute.type.target_name == model.reference_target.to_s
          end.map(&:name)
        end

        def satisfies_wheres?(model, state, args)
          model.wheres.all? do |clause|
            Ports::Query::InMemory.holds?(clause, comparable_field(state, clause.field), args)
          end
        end
      end
    end
  end
end
