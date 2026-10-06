require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../rendering"

module Hecks
  module Runtime
    class Value
      # Checks on what a scalar or patterned field may hold. Mixed into {FieldChecks}.
      module ShapeChecks
        private

        def check_scalar_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            scalar_items(attribute, fields[attribute.name]).each do |item|
              next unless misshapen_scalar?(attribute.type.to_s, item)

              numeric_field_mismatch!(value_object.hecks_name, attribute.name, attribute.type, Rendering.describe(item))
            end
          end
        end

        # The offered values of a String or boolean field; none for any other field or a nil.
        def scalar_items(attribute, given)
          return [] unless FieldChecks::NON_NUMERIC_SCALARS.include?(attribute.type.to_s) && !given.nil?

          offered_items(attribute, given)
        end

        # A composite standing in for a leaf, or a non-String standing in for a String.
        def misshapen_scalar?(type, item)
          composite = FieldChecks::COMPOSITE_SHAPES.any? { |shape| item.is_a?(shape) }
          composite || (type == "String" && !item.is_a?(String) && !judge_bootstrapping?)
        end

        # A field declared with a pattern must match it, refused as a TypeMismatch
        # rather than surfacing later as a broken predicate. The pattern itself is
        # already vetted by PatternSubset when the bluebook is declared. `^` and `$` match the
        # whole value, as in Rust, so a newline cannot smuggle text past an anchored pattern.
        def check_patterns(value_object, fields)
          value_object.attributes.each do |attribute|
            pattern = attribute.pattern
            given   = fields[attribute.name]
            next unless pattern && !given.nil?

            offered_items(attribute, given).each { |item| check_pattern_item!(value_object, attribute, item) }
          end
        end

        def check_pattern_item!(value_object, attribute, item)
          pattern = attribute.pattern
          return if item.is_a?(String) && Regexp.new(Hecks::Bluebook::PatternSubset.whole_string(pattern)).match?(item)

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "pattern_mismatch",
                                           type: value_object.hecks_name, field: attribute.name,
                                           pattern: pattern, offered: Rendering.describe(item))
        end
      end
    end
  end
end
