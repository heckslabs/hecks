require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class Value
      # Renders a value object as the bare scalar it holds, and builds one back from a derived
      # identity string. Extended into `Value` beside `Coercion`.
      module Identifiers
        # Renders a value object into the bare scalar its one field holds — for a
        # column or a message, where there is no path to consult.
        #
        # @param value [Object] the value to render; passed through unless a `Runtime::Value`
        # @return [Object] `value` unchanged, or its one field's own value
        # @raise [Runtime::TypeMismatch] if `value` has more than one field
        def scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          return fields.values.first if fields.size == 1

          raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "multi_field_scalar", type: value.type_name)
        end

        # Coerces a derived identity string back into `attribute`'s own declared type.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct
        #   `attribute` is declared on
        # @param attribute [Bluebook::Attribute] the identity attribute to coerce for
        # @param identifier [String, Object] the derived identity
        # @return [Runtime::Value, String, Object] a built value object for a
        #   single-field value-object type; `identifier` unchanged otherwise
        # @raise [Runtime::TypeMismatch] if the type names a multi-field value object
        def from_identifier(aggregate, attribute, identifier)
          value_object = value_object_for(aggregate, attribute.type)
          return identifier unless value_object

          fields = value_object.attributes
          if fields.size == 1
            field = fields.first
            return build(value_object, { field.name => coerce_identifier(field, identifier) })
          end

          raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "composite_identity", type: value_object.hecks_name)
        end

        private

        # Converts a derived numeric identity string back before `check_numeric_fields` runs.
        def coerce_identifier(field, identifier)
          return identifier unless identifier.is_a?(String) && FieldChecks::NUMERIC.key?(field.type.to_s)

          case field.type.to_s
          when "Integer" then Integer(identifier)
          when "Float"   then Float(identifier)
          else identifier
          end
        rescue ArgumentError
          identifier
        end
      end
    end
  end
end
