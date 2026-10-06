require_relative "../../bluebook/expression/evaluator"
require_relative "../../naming"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "invariant_violation"

module Hecks
  module Runtime
    class Value
      # Class-side coercion engine for Value, extended in so its methods read
      # as `Value.for`, `Value.build`, and so on.
      module Coercion
        # The complete set of attribute value shapes. Mirrored by hand into a
        # generated Rust enum (hecks project_kernel_capabilities) — adding a shape
        # here without a matching Rust file leaves the kernel unaware of it.
        SHAPES = %i[scalar list optional composite].freeze

        # Coerces `value` for one of `aggregate`'s declared attributes, by name.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct to look
        #   up `name` on
        # @param name [String, Symbol] the declared attribute name
        # @param value [Object] the raw value to coerce
        # @return [Runtime::Value, Object, nil] the coerced value, or `value`
        #   unchanged if `aggregate` declares no such attribute
        # @raise [Runtime::TypeMismatch] if `value` cannot be coerced to the declared type
        # @raise [Runtime::UnknownArgument] if `value` is a Hash naming an undeclared field
        # @raise [Runtime::InvariantViolation] if a coerced value object breaks an invariant
        def for(aggregate, name, value)
          attribute = aggregate.attribute(name)
          return value unless attribute

          for_attribute(aggregate, attribute, value)
        end

        # Coerces `value` for a single, already-resolved `attribute`, branching on
        # its declared shape (list, reference, composite, or bare scalar).
        #
        # `boundary: false` is the query door, where a declared type documents the
        # argument for callers/generators rather than naming a shape to enforce.
        # `argument: true` is the command/entity/port dispatch door, where a nil for
        # a required attribute is a left-empty argument (C3.7), not ordinary state nil.
        #
        # @raise [Runtime::TypeMismatch] if `value` cannot be coerced, or a required
        #   reference/attribute is a wrong-shaped value
        # @raise [Runtime::UnknownArgument] if `value` is a Hash naming an undeclared field
        # @raise [Runtime::InvariantViolation] if a coerced value object breaks an invariant
        def for_attribute(aggregate, attribute, value, boundary: true, argument: false)
          return nil_or_missing(aggregate, attribute, value, argument) if attribute.nil? || value.nil?
          return reference_or_list(aggregate, attribute, value) if attribute.list? || attribute.reference?
          return value unless aggregate.respond_to?(:value_object)

          coerce_scalar(aggregate, attribute, value, boundary)
        end

        # Resolves the value-object class `type` names: `aggregate`'s own
        # declarations first, then its chapter's other aggregates if they agree.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct to search first
        # @param type [String, Symbol, #to_s] the declared type name to resolve
        # @return [Class, nil] the `Bluebook::ValueObject` subclass `type` names, or nil
        def value_object_for(aggregate, type)
          local = aggregate.value_object(type)
          return local if local

          chapter = aggregate.respond_to?(:hecks_owner) ? aggregate.hecks_owner : nil
          return nil unless chapter.respond_to?(:aggregates)

          agreed_value_object(chapter, type)
        end

        # Normalizes an offered value into `value_object`'s own field Hash, before
        # defaults, nested normalization and validation run.
        #
        # @param value_object [Class] the target `Bluebook::ValueObject` subclass
        # @param name [String, Symbol] the attribute or argument name, quoted in a refusal
        # @param value [Hash, Runtime::Value, Object] a Hash of fields, an already-built
        #   `Value`, or a bare scalar for a single-field value object
        # @return [Hash{Symbol => Object}] the offered fields, keyed by attribute name
        # @raise [Runtime::TypeMismatch] if `value` is a bare scalar and `value_object`
        #   declares more than one field
        def fields_for(value_object, name, value)
          return value.transform_keys(&:to_sym) if value.is_a?(Hash)
          # A same-shaped value object may fill a differently-named slot (e.g.
          # PositiveMoney into an Account's Money balance) — rebuild from its state.
          return value.to_h if value.is_a?(self)

          # A bare scalar auto-wraps into a single-field value object's sole
          # attribute, matching `from_identifier`'s own precedent. Multi-field
          # value objects still refuse below.
          return { value_object.attributes.first.name => value } if value_object.attributes.size == 1

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "value_object_shape",
                                           name: name, type: value_object.hecks_name,
                                           offered: Rendering.describe(value))
        end

        # Builds one validated `Value` of `value_object`'s own type: defaults filled,
        # nested fields normalized and validated, then the whole thing checked.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass to build
        # @param fields [Hash{Symbol, String => Object}] the offered field values,
        #   either key spelling
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity, nil] construct a
        #   nested composite field resolves against; nil skips nested normalization
        # @return [Runtime::Value] the built, validated value object
        # @raise [Runtime::UnknownArgument] if a field names an undeclared key
        # @raise [Runtime::TypeMismatch] if a field cannot be coerced to its declared type
        # @raise [Runtime::InvariantViolation] if the built value object breaks an invariant
        def build(value_object, fields, aggregate = nil)
          fields = apply_defaults(value_object, fields.transform_keys(&:to_sym))
          fields = normalize_composite_fields(aggregate, value_object, fields)
          validate!(value_object, fields)
          new(value_object, fields)
        end

        # State arrives decoded or not at all: every persistence adapter symbolizes
        # keys before this point, so a String key here means a caller skipped that
        # step — refused by name rather than silently respelled.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct whose
        #   declared attributes coerce `state`'s own values
        # @param state [Hash{Symbol => Object}] the stored state to hydrate; every
        #   key must already be a Symbol
        # @return [Hash{Symbol => Object}] `state`, coerced through each declared attribute
        # @raise [Runtime::WiringError] if `state` holds any non-Symbol key
        def hydrate(aggregate, state)
          refuse_undecoded_keys!(aggregate, state)

          trusting_stored_state do
            state.each_with_object({}) do |(key, value), hydrated|
              attribute = aggregate.attribute(key)
              hydrated[key] = attribute ? for_attribute(aggregate, attribute, value) : value
            end
          end
        end

        private

        # A list or a reference: each has its own coercion.
        def reference_or_list(aggregate, attribute, value)
          return reference_list(attribute, value) if attribute.list? && attribute.reference?
          return reference_identity(attribute, value) if attribute.reference?

          hydrate_entity_list(aggregate, attribute, value)
        end

        # A bare scalar or a value object. `admits:` is checked here, where the attribute is
        # known — `build` only sees the value object. Checked after coercion: a scalar arrives
        # wrapped in its type's own holder, and checking the raw payload would be wrong.
        def coerce_scalar(aggregate, attribute, value, boundary)
          value_object = value_object_for(aggregate, attribute.type)
          return bare_primitive(aggregate, attribute, value, boundary) if value_object.nil?

          coerced = if value.is_a?(self) && value.type_name == value_object.hecks_name
                      value
                    else
                      build(value_object, fields_for(value_object, attribute.name, value), aggregate)
                    end

          admit_declared_set(aggregate, attribute, coerced)
          coerced
        end

        # The one value object every aggregate of the chapter that declares `type` agrees on.
        def agreed_value_object(chapter, type)
          matches = chapter.aggregates.filter_map { |candidate| candidate.value_object(type) }
          shapes = matches.group_by do |shape|
            shape.attributes.map { |field| [field.name, field.type.to_s, field.list?, field.optional?] }
          end
          shapes.size == 1 ? matches.first : nil
        end

        # A required argument's nil is refused (C3.7); state assembly, hydration
        # and query nils pass through unchanged. Lists/references keep their own
        # nil passthrough regardless of `argument`.
        def nil_or_missing(aggregate, attribute, value, argument)
          return value if attribute.nil? || !value.nil?

          argument ? nil_argument(aggregate, attribute) : value
        end

        def nil_argument(aggregate, attribute)
          return nil if attribute.optional? || trusting_stored_state?
          return nil if attribute.list? || attribute.reference?

          value_object = aggregate.respond_to?(:value_object) ? value_object_for(aggregate, attribute.type) : nil
          return build(value_object, {}, aggregate) if value_object

          numeric_field_mismatch!(aggregate.hecks_name, attribute.name, attribute.type, "nil")
        end

        # A bare primitive is boundary-checked too (C3.8) — wrong-typed input
        # refuses here as a TypeMismatch, never later as a broken predicate.
        # Its `admits:` set is still checked, exactly as a value object's is.
        def bare_primitive(aggregate, attribute, value, boundary)
          check_bare_primitive(aggregate, attribute, value) if boundary
          admit_declared_set(aggregate, attribute, value)
          value
        end

        def refuse_undecoded_keys!(aggregate, state)
          undecoded = state.keys.grep_v(Symbol)
          return if undecoded.empty?

          raise WiringError,
                "#{aggregate.name} state reached hydration with non-Symbol keys #{undecoded.inspect} — " \
                "decode stored state through Hecks::Ports::Persistence::StateCodec.decode first"
        end
      end
    end
  end
end
