module Hecks
  module Runtime
    class Value
      # The shape a caller is answered with: a single-attribute value object as its bare field,
      # following the declared types down through nested value objects and lists. Extended into
      # `Value` beside `Coercion`; `materialize` keeps the wrapped shape stored state depends on.
      module Unwrapping
        # `materialize`, but a single-attribute value object unwraps to its bare field. What
        # `group_by` rows and `Driving::Json.materialize` answer with.
        #
        # @param value [Object] the value to materialize; anything that is not a `Runtime::Value`,
        #   Array or Hash passes through unchanged
        # @return [Object] `value` with every nested `Runtime::Value` replaced by its own sole
        #   field's value (recursively unwrapped), or by its own `Hash` of fields when it has
        #   more than one
        def materialize_unwrapped(value)
          case value
          when self then unwrap_typed(value.value_object, value.raw_fields)
          when Array then value.map { |item| materialize_unwrapped(item) }
          when Hash then value.transform_values { |item| materialize_unwrapped(item) }
          else value
          end
        end

        private

        # A value object's fields by its declared attributes. A nested value object is often held
        # as a plain Hash, so its own type is looked up rather than read off the field.
        def unwrap_typed(value_object, fields)
          sole = value_object.sole_attribute
          return unwrap_field(value_object, sole, fields[sole.name]) if sole

          value_object.attributes.to_h { |attr| [attr.name, unwrap_field(value_object, attr, fields[attr.name])] }
        end

        def unwrap_field(value_object, attribute, held)
          case held
          when Array then held.map { |item| unwrap_field(value_object, attribute, item) }
          when Hash then unwrap_held_hash(value_object, attribute, held)
          else materialize_unwrapped(held)
          end
        end

        def unwrap_held_hash(value_object, attribute, held)
          nested = nested_value_object(value_object, attribute.type)
          return materialize_unwrapped(held) unless nested

          unwrap_typed(nested, held.transform_keys(&:to_sym))
        end

        # The value object a field's type names, resolved against the aggregate that declares
        # `value_object`; nil for a primitive, or when the owner is not known.
        def nested_value_object(value_object, type)
          owner = value_object.respond_to?(:hecks_owner) ? value_object.hecks_owner : nil
          owner.respond_to?(:value_object) ? value_object_for(owner, type) : nil
        end
      end
    end
  end
end
