require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class ReadModelInterpreter
      # How a read model's rows are shaped for the answer: each head as rows, nested by
      # `group_by`, or reduced to one value. Mixed into {ReadModelInterpreter}.
      module Shaping
        # What `shaped_head` needs of the read model: the model, its bluebook, and the heads the
        # `group_by` and the reduction apply to.
        Shape = Struct.new(:model, :bluebook, :grouped, :reduced)

        private

        # Declared order is preserved in the output — only the computation of the heads
        # needed reordering.
        def shape_heads(model, bluebook, rows_by_as)
          heads = model.aggregate_heads.to_h { |head| [head[:as], rows_by_as[head[:as]]] }
          shape = Shape.new(model, bluebook, group_by_target(model, bluebook), aggregation_target(model, bluebook))
          [heads.to_h { |as, value| [as, shaped_head(as, value, shape)] }]
        end

        def shaped_head(as, value, shape)
          return grouped_rows(value, shape) if shape.grouped && as == shape.grouped[:as]
          return reduced_value(value, shape.model) if shape.reduced && as == shape.reduced[:as]

          plain_head(value)
        end

        def plain_head(value)
          value.is_a?(Array) ? value.map { |record| Value.materialize(row(record)) } : Value.materialize(row(value))
        end

        # A grouped head nests its rows; with a reduction declared too, each leaf is that
        # reduction of the leaf's rows rather than the row itself (ADR 0126).
        def grouped_rows(value, shape)
          model = shape.model
          rows = value.map { |record| Value.materialize_unwrapped(row(record)) }
          leaf = shape.reduced ? reduced_leaf(model) : row_leaf(collision_check(model, shape.bluebook, shape.grouped))
          nest(rows, model.group_by_fields, leaf)
        end

        def reduced_leaf(model) = ->(rows, _path) { reduced_value(rows, model) }

        def row_leaf(checked) = ->(rows, path) { leaf(rows, checked, path) }

        def reduced_value(value, model)
          model.count? ? value.length : reduce(model, value)
        end

        # Resolves `group_by`'s target head and validates its fields once, raising on
        # a typo'd field name rather than silently grouping every row under `nil`.
        def group_by_target(model, bluebook)
          return nil unless model.group_by.any?

          target = model.aggregate_heads.find { |head| head[:many] }
          aggregate = bluebook.aggregate(target[:aggregate])
          model.group_by_fields.each { |field| check_group_field!(model, aggregate, target, field) }
          target
        end

        def check_group_field!(model, aggregate, target, field)
          return if aggregate.attribute(field)

          # A lifecycle field is a real field too — it's stored on the record like
          # any attribute, just declared via `lifecycle :status`, and it's usually
          # exactly the field a report wants to group by.
          lifecycle_field = aggregate.lifecycle_field
          return if lifecycle_field && lifecycle_field.to_sym == field.to_sym

          raise ArgumentError,
                "#{model.name}'s group_by names #{field.inspect}, but #{target[:aggregate]} " \
                "declares no such attribute (it declares #{aggregate.attributes.map(&:name).join(", ")})"
        end

        # Whether `group_by` leaves must hold one row, decided from the declaration
        # alone (ADR 0061 D1): nil when the key path already covers the identity.
        def collision_check(model, bluebook, grouped_head)
          model.groups_by_identity?(bluebook.aggregate(grouped_head[:aggregate])) ? nil : model
        end

        # Nests one level per `group_by` field, answering each leaf's rows through `leaf`.
        def nest(rows, fields, leaf, reached = [])
          field, *rest = fields
          rows.group_by { |row| row[field] }.to_h do |key, group|
            # Strip only the field just grouped by, not the whole remaining
            # list — `rest`'s own fields have to survive into the recursive
            # call below, or the next level groups by a key that's already gone.
            stripped = group.map { |row| row.reject { |name, _| name == field } }
            path = reached + [[field, key]]
            [key, rest.empty? ? leaf.call(stripped, path) : nest(stripped, rest, leaf, path)]
          end
        end

        # The one row a key path reached; more than one is a `group_by` collision
        # (ADR 0061 D1), refused rather than picking one.
        def leaf(rows, checked, path)
          return rows.first unless checked && rows.size > 1

          raise InvariantViolation,
                RefusalWording.render_site("InvariantViolation", "group_by_collision",
                                           read_model: checked.name, fields: checked.group_by_fields,
                                           ids: rows.map { |row| row[:id] },
                                           key: path.map { |field, value| "#{field} = #{value}" }.join(", "))
        end
      end
    end
  end
end
