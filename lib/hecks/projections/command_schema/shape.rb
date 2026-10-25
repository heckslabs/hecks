require_relative "../../forms/field_shape"

module Hecks
  module Projections
    module CommandSchema
      # One declared attribute as a JSON Schema, in the same branch order as
      # `Forms::FieldShape.resolve` so a form and a schema agree about what a field is: a list, a
      # reference, an `admits:` set, a value object (closed set, money, a single field or a group),
      # then a primitive.
      #
      # A `pattern:` is emitted as authored: the runtime searches it, as JSON Schema does, and the
      # pattern subset keeps `^` and `$` to text anchors that every engine reads the same way.
      #
      # The wire accepts a single-field value object as its bare value or as an object holding the
      # field, so the schema allows both; a multi-field value object must be an object.
      module Shape
        JSON_TYPES = { "String" => "string", "Integer" => "integer", "Float" => "number",
                       "TrueClass" => "boolean", "FalseClass" => "boolean" }.freeze

        PRIMITIVES = Bluebook::Attribute::PRIMITIVES

        module_function

        # @param attribute [Bluebook::Attribute] a command's attribute
        # @param aggregate [Bluebook::Aggregate] the aggregate that owns the command
        # @return [Hash{String => Object}] the property's schema, with its default if it has one
        def property(attribute, aggregate)
          schema = scalar(attribute, aggregate)
          schema = { "type" => "array", "items" => schema } if attribute.list?
          attribute.default.nil? ? schema : schema.merge("default" => attribute.default)
        end

        # @return [Hash{String => Object}] an object schema over `attributes`; a field is required
        #   unless it is optional or has a default the runtime fills
        def object(attributes, aggregate)
          { "type"                 => "object",
            "properties"           => attributes.to_h { |inner| [inner.name.to_s, property(inner, aggregate)] },
            "required"             => required_names(attributes),
            "additionalProperties" => false }
        end

        # @return [Array<String>] the names a payload must carry: not optional, no default to fill
        def required_names(attributes)
          required = attributes.reject { |inner| inner.optional? || !inner.default.nil? }
          required.map { |inner| inner.name.to_s }
        end

        def scalar(attribute, aggregate)
          return { "type" => "string", "x-references" => attribute.target_name.to_s } if attribute.reference?
          return admitted(attribute, aggregate) if attribute.admits
          return value_object(attribute, aggregate) unless PRIMITIVES.include?(attribute.type)

          primitive(attribute)
        end

        def primitive(attribute)
          schema = { "type" => JSON_TYPES.fetch(attribute.type.to_s, "string") }
          attribute.pattern ? schema.merge("pattern" => attribute.pattern.to_s) : schema
        end

        def admitted(attribute, aggregate)
          set = Forms::FieldShape.admitted_set(attribute, aggregate)
          return primitive(attribute) unless set

          members = enum(set)
          own = Forms::FieldShape.own_value_object(attribute, aggregate)
          inner = own && Forms::ValueObjectShape.sole_attribute(own)
          inner ? bare_or_object(inner.name, members) : members
        end

        def value_object(attribute, aggregate)
          shape = Forms::FieldShape.own_value_object(attribute, aggregate)
          return primitive(attribute) unless shape
          return bare_or_object(shape.attributes.first.name, enum(shape)) if shape.closed_set?

          inner = Forms::ValueObjectShape.sole_attribute(shape)
          return bare_or_object(inner.name, property(inner, aggregate)) if inner

          object(shape.attributes, aggregate)
        end

        # @return [Hash{String => Object}] the closed set's members, by their discriminant
        def enum(set)
          { "type" => "string", "enum" => Forms::FieldShape.closed_set_options(set) }
        end

        # @return [Hash{String => Object}] the bare value, or an object holding it as `field`
        def bare_or_object(field, schema)
          { "anyOf" => [schema, { "type" => "object", "properties" => { field.to_s => schema },
                                  "required" => [field.to_s], "additionalProperties" => false }] }
        end
      end
    end
  end
end
