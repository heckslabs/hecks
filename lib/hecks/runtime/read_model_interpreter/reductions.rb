require_relative "../../ports/query/in_memory"
require_relative "../../query_specification/field_path"

module Hecks
  module Runtime
    class ReadModelInterpreter
      # The reductions a read model can declare (`count`, `sum`, `avg`, `min`, `max`, `any`,
      # `all`, `median`, `percentile`): validated against the head's attributes, then applied to
      # the head's rows. Mixed into {ReadModelInterpreter}.
      module Reductions
        # The reduction a model declares, with its declared field, for a refusal message.
        Reduction = Struct.new(:model, :ivar, :word, :field)

        # The order `reduce` looks for a declared reduction; `median` is what remains.
        REDUCE_ORDER = %i[any_field all_field sum_field avg_field min_field max_field percentile_field].freeze

        private

        # Resolves a reduction's single many-side head, raising on a field that doesn't
        # exist or has the wrong type rather than comparing garbage.
        def aggregation_target(model, bluebook)
          return nil unless model.reducing?

          target = model.aggregate_heads.find { |head| head[:many] }
          return target if model.count?

          validate_reduction!(model, bluebook, target)
          target
        end

        def validate_reduction!(model, bluebook, target)
          ivar, word = REDUCTION_WORD.find { |name, _| model.public_send(name) }
          field = model.public_send(ivar)
          aggregate = bluebook.aggregate(target[:aggregate])
          attribute = aggregate.attribute(field)
          raise ArgumentError, undeclared_reduction_field(model, word, field, target, aggregate) unless attribute

          validate_reduction_type!(Reduction.new(model, ivar, word, field), target[:aggregate], aggregate, attribute)
        end

        def undeclared_reduction_field(model, word, field, target, aggregate)
          "#{model.name}'s #{word} names #{field.inspect}, but #{target[:aggregate]} " \
            "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(", ")})"
        end

        # @raise [ArgumentError] if `attribute` does not have the type the reduction needs
        def validate_reduction_type!(reduction, aggregate_name, aggregate, attribute)
          return if reduction_type_ok?(reduction.ivar, aggregate, attribute)

          kind = BOOLEAN_REDUCTIONS.include?(reduction.ivar) ? "boolean" : "numeric"
          raise ArgumentError,
                "#{reduction.model.name}'s #{reduction.word} names #{reduction.field.inspect} on #{aggregate_name}, " \
                "which is not #{kind} — #{reduction.word} needs a #{kind == "boolean" ? "true/false" : "numeric"} field"
        end

        def reduction_type_ok?(ivar, aggregate, attribute)
          wrap = ->(type) { aggregate.value_object(type) }
          if BOOLEAN_REDUCTIONS.include?(ivar)
            QuerySpecification::FieldPath.boolean?(attribute, [], &wrap)
          elsif INTEGER_ONLY_REDUCTIONS.include?(ivar)
            QuerySpecification::FieldPath.integer?(attribute, [], &wrap)
          else
            QuerySpecification::FieldPath.numeric?(attribute, [], &wrap)
          end
        end

        # Dispatches to the one reduction `model` declares, over the eligible collection's own
        # `comparable`-mapped values (or raw booleans for `any`/`all`) — the interpretation of
        # `Runtime::ReadModelInterpreter#project`'s `reduced_head` branch.
        def reduce(model, rows)
          name = REDUCE_ORDER.find { |candidate| model.public_send(candidate) }
          return percentile(numeric_values(rows, model.median_field), 0.5) unless name

          apply_reduction(name, model, rows)
        end

        def apply_reduction(name, model, rows)
          field = model.public_send(name)
          case name
          when :any_field then boolean_values(rows, field).any?
          when :all_field then boolean_values(rows, field).all?
          else numeric_reduction(name, model, numeric_values(rows, field))
          end
        end

        def numeric_reduction(name, model, values)
          case name
          when :sum_field then values.sum
          when :avg_field then average(values)
          when :min_field then values.min
          when :max_field then values.max
          else percentile(values, model.percentile_at)
          end
        end

        # Shared by every reduction: `comparable` unwraps a value-object-wrapped field down to
        # its sole member (numeric or boolean alike) exactly as `where`/`order_by` already read
        # it, so `flagged: { value: true }` reduces on the boolean, not the ever-truthy Hash.
        def reduction_values(rows, field)
          # `compact`, not `filter_map`: a stored `false` is a real value, not an absent one.
          rows.map { |record| Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row(record), field)) }.compact
        end
        alias numeric_values reduction_values
        alias boolean_values reduction_values

        # `nil` on no rows: a rate of nothing is undefined, not zero.
        def average(values) = values.empty? ? nil : values.sum.to_f / values.length

        # The value at one interpolated rank (`0.0`..`1.0`); `at: 0.5` is the standard median
        # (middle value when odd, average of the two middle values when even). `nil` on no rows.
        def percentile(values, at)
          return nil if values.empty?

          sorted = values.sort
          position = at * (sorted.length - 1)
          lower = position.floor
          fraction = position - lower
          fraction.zero? ? sorted[lower] : sorted[lower] + (fraction * (sorted[lower + 1] - sorted[lower]))
        end
      end
    end
  end
end
