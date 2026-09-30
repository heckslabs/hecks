require "json"
require_relative "../rendering"
require_relative "value/invariant_violation"
require_relative "value/field_checks"
require_relative "value/coercion"
require_relative "value/entity_list_coercion"
require_relative "value/admission"

module Hecks
  module Runtime
    # A typed value object: frozen fields, read by name.
    # Construction lives in value/coercion.rb, field_checks.rb, entity_list_coercion.rb and
    # admission.rb.
    class Value
      extend FieldChecks
      extend Coercion
      extend EntityListCoercion
      extend Admission

      attr_reader :value_object

      # Deep-freezes the fields so a held String, Array or Hash cannot be mutated in place.
      #
      # @param value_object [Bluebook::ValueObject] the declared type this instance is one of
      # @param fields [Hash] the type's fields, keyed by name (String or Symbol); deep-frozen
      #   and stored with Symbol keys
      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = Freezer.deep(fields.transform_keys(&:to_sym))
        freeze
      end

      # Reads the declared type's own name.
      #
      # @return [String] the value object's `hecks_name`
      def type_name = @value_object.hecks_name

      # Reads one field.
      #
      # @param field [String, Symbol] the field name; `:value` reads the sole field of a
      #   single-attribute value object, whatever it is actually named
      # @return [Object, nil] the field's coerced value; nil if the field is not held
      def [](field) = @fields[resolve_field(field)]

      # Answers whether this value object holds the named field.
      #
      # @param field [String, Symbol] the field name; `:value` resolves the same way `[]` does
      # @return [Boolean] true when the field is held
      def key?(field) = @fields.key?(resolve_field(field))
      def to_h = @fields.transform_values { |value| self.class.materialize(value) }

      # Renders this value object as JSON, through the same shape `to_h` builds.
      #
      # @return [String] a JSON object of the materialized fields
      def to_json(*) = JSON.generate(to_h)

      def ==(other)
        other.is_a?(self.class) && other.type_name == type_name && other.to_h == to_h
      end

      # Builds a new value object of the same type with one field replaced, re-validated.
      #
      # @param field [String, Symbol] the field to replace; `:value` resolves the same way
      #   `[]` does
      # @param value [Object] the field's new, uncoerced value
      # @return [Runtime::Value] a new instance of the same type, with `field` replaced
      # @raise [Runtime::TypeMismatch] if the new fields do not satisfy the type's declared
      #   shape (an unknown field, a missing required one, a wrong numeric type, …)
      # @raise [Runtime::InvariantViolation] if the new fields violate one of the type's own
      #   invariants, or are not a member of its closed set
      def with(field, value)
        self.class.build(@value_object, @fields.merge(resolve_field(field) => value))
      end

      # Recursively converts a `Runtime::Value` (and any nested inside a Hash or Array) to
      # plain data.
      #
      # @param value [Object] the value to materialize; anything that is not a `Runtime::Value`,
      #   Array or Hash passes through unchanged
      # @return [Object] `value` with every nested `Runtime::Value` replaced by its own `to_h`
      def self.materialize(value)
        case value
        when self then value.to_h
        when Array then value.map { |item| materialize(item) }
        when Hash then value.transform_values { |item| materialize(item) }
        else value
        end
      end

      # `materialize`, but a single-attribute value object unwraps to its bare field.
      # Opt-in for `group_by` rows; `materialize` keeps the wrapped shape callers depend on.
      #
      # @param value [Object] the value to materialize; anything that is not a `Runtime::Value`,
      #   Array or Hash passes through unchanged
      # @return [Object] `value` with every nested `Runtime::Value` replaced by its own sole
      #   field's value (recursively unwrapped), or by its own `Hash` of fields when it has
      #   more than one
      def self.materialize_unwrapped(value)
        case value
        when self
          sole = value.value_object.sole_attribute
          return materialize_unwrapped(value[sole.name]) if sole

          # Not `value.to_h`: it materializes nested values to Hashes, ending the recursion.
          value.value_object.attributes.to_h { |attr| [attr.name, materialize_unwrapped(value[attr.name])] }
        when Array then value.map { |item| materialize_unwrapped(item) }
        when Hash then value.transform_values { |item| materialize_unwrapped(item) }
        else value
        end
      end

      # Reduces an append-only `list_of` sub-log to its current state: the latest row per `key`.
      # Grouping only; what counts as removed, and the ordering, belong to the caller.
      #
      # @param rows [Array<Runtime::Value>] a `list_of` attribute's own elements, in append order
      # @param key [Symbol] the method to call on each row to find "the same logical thing"
      #   across entries (typically a field reader)
      # @return [Array<Runtime::Value>] one row per distinct `key` value, each the latest row
      #   that had it
      def self.latest_by(rows, key)
        rows.to_h { |row| [row.public_send(key), row] }.values
      end

      def method_missing(name, *args)
        return @fields[name] if @fields.key?(name)

        # `.value` aliases the sole field of a single-attribute value object; after the real-field
        # lookup so a field literally named `value` is never shadowed.
        if name == :value
          sole = @value_object.sole_attribute
          return @fields[sole.name] if sole
        end

        super
      end

      def respond_to_missing?(name, include_private = false)
        return true if @fields.key?(name)
        return true if name == :value && @value_object.sole_attribute

        super
      end

      private

      # Resolves `:value` to the sole field's name so `[]`, `key?`, `with` match `method_missing`.
      # A real key always wins.
      def resolve_field(field)
        sym = field.to_sym
        return sym if @fields.key?(sym)

        if sym == :value
          sole = @value_object.sole_attribute
          return sole.name if sole
        end

        sym
      end
    end
  end
end
