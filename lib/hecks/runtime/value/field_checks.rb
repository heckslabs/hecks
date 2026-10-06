require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../rendering"
require_relative "shape_checks"

module Hecks
  module Runtime
    class Value
      # Boundary checks that refuse a mistyped, unknown, missing or malformed field before an
      # invariant reads it; extended into `Value` alongside `Coercion`, which calls them.
      module FieldChecks
        include ShapeChecks

        # C3.3/C3.4 — value bounds enforced at every boundary: an Integer must fit
        # signed 64 bits, a Float must be finite.
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        # Checked before invariants, because an invariant reading a mistyped field
        # is exactly the thing that would otherwise explode.
        NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze

        # A scalar field (String, or a boolean) must not arrive as a composite
        # (Array/Hash) standing in for a leaf value. A String field additionally
        # must not arrive as any other scalar, except inside `judge_bootstrapping?`.
        COMPOSITE_SHAPES = [Array, ::Hash].freeze
        NON_NUMERIC_SCALARS = %w[String TrueClass FalseClass].freeze

        private

        # The refusal every wrong-typed or missing field shares: `type_name`'s `field_name` was
        # offered `offered` where `expected` was declared.
        def numeric_field_mismatch!(type_name, field_name, expected, offered)
          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "numeric_field",
                                           type: type_name, field: field_name, expected: expected, offered: offered)
        end

        # C3.8 boundary check — refuses a mistyped argument before it breaks a predicate.
        def check_bare_primitive(owner, attribute, value)
          type = attribute.type.to_s
          numeric_field_mismatch!(owner.hecks_name, attribute.name, type, Rendering.describe(value)) if mistyped?(type, value)

          check_numeric_bounds(owner.hecks_name, attribute.name, value)
        end

        def mistyped?(type, value)
          expected = NUMERIC[type]
          return !value.is_a?(expected) if expected

          NON_NUMERIC_SCALARS.include?(type) && COMPOSITE_SHAPES.any? { |shape| value.is_a?(shape) }
        end

        def check_numeric_bounds(type_name, field_name, given)
          if given.is_a?(Integer) && !INT64_RANGE.cover?(given)
            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "integer_range",
                                             type: type_name, field: field_name, offered: Rendering.describe(given))
          end
          return unless given.is_a?(Float) && !given.finite?

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "non_finite_field",
                                           type: type_name, field: field_name, offered: Rendering.describe(given))
        end

        # A value object refuses an undeclared key the same way a command's own
        # payload does, checked before any other field-content check.
        def check_unknown_fields(value_object, fields)
          known   = value_object.attributes.map { |attribute| attribute.name.to_sym }
          unknown = (fields.keys.map(&:to_sym) - known).sort
          return if unknown.empty?

          declared = value_object.attributes.map(&:name)
          raise UnknownArgument,
                RefusalWording.render_site("UnknownArgument", "unknown_args",
                                           command: value_object.hecks_name, unknown: unknown,
                                           declared: declared)
        end

        # C3.7 — every non-optional, non-list field must arrive (or construction
        # refuses); a `default:` has already been filled in by `apply_defaults`.
        def check_required_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            next if attribute.optional? || attribute.list?
            next unless fields[attribute.name].nil?

            numeric_field_mismatch!(value_object.hecks_name, attribute.name, attribute.type, "nil")
          end
        end

        def check_numeric_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            expected = NUMERIC[attribute.type.to_s]
            given    = fields[attribute.name]
            next unless expected && !given.nil?

            offered_items(attribute, given).each { |item| check_numeric_item!(value_object, attribute, expected, item) }
          end
        end

        def check_numeric_item!(value_object, attribute, expected, item)
          unless item.is_a?(expected)
            numeric_field_mismatch!(value_object.hecks_name, attribute.name, attribute.type, Rendering.describe(item))
          end

          # `is_a?(expected)` alone waves NaN/Infinity through — both are real
          # Floats. `-0.0` is deliberately left unchecked: finite and legitimate.
          check_numeric_bounds(value_object.hecks_name, attribute.name, item)
        end

        # A `list_of` field holds an Array whatever its element type, so a lone scalar
        # offered for it is refused; nil stays legitimate, as it is for any optional field.
        def check_list_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            given = fields[attribute.name]
            next unless attribute.list? && !given.nil? && !given.is_a?(Array)

            numeric_field_mismatch!(value_object.hecks_name, attribute.name, "list_of(#{attribute.type})",
                                    Rendering.describe(given))
          end
        end

        # The values a field's element-level checks apply to: each element of a list, or the
        # one value of a scalar field.
        def offered_items(attribute, given) = attribute.list? && given.is_a?(Array) ? given : [given]
      end
    end
  end
end
