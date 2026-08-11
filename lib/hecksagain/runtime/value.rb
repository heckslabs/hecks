require "json"
require_relative "../rendering"
require_relative "value/invariant_violation"
require_relative "value/coercion"
require_relative "value/admission"

module Hecksagain
  module Runtime
    # A typed value object in hand: frozen fields, read by name. How one is
    # MADE — coerced from a raw argument, checked against its declared
    # numeric types, patterns and closed sets — is the class-side engine in
    # value/coercion.rb and value/admission.rb, extended here so the door
    # stays where it always was: `Value.for`, `Value.build`.
    class Value
      extend Coercion
      extend Admission

      attr_reader :value_object

      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = fields.transform_keys(&:to_sym).freeze
      end

      def type_name = @value_object.hecks_name
      def [](field) = @fields[field.to_sym]
      def key?(field) = @fields.key?(field.to_sym)
      def to_h = @fields.transform_values { |value| self.class.materialize(value) }
      def to_json(*) = JSON.generate(to_h)

      def ==(other)
        other.is_a?(self.class) && other.type_name == type_name && other.to_h == to_h
      end

      def with(field, value)
        self.class.build(@value_object, @fields.merge(field.to_sym => value))
      end

      def self.materialize(value)
        case value
        when self then value.to_h
        when Array then value.map { |item| materialize(item) }
        when Hash then value.transform_values { |item| materialize(item) }
        else value
        end
      end

      # `materialize`, but a single-attribute value object (`sole_attribute`
      # — [[feedback_name_the_scalar_field]]) recurses into its own bare
      # field instead of building `{field: ...}` — a Board's own `label`
      # unwraps to `"Kanban"`, not `{value: "Kanban"}`. NOT a replacement
      # for `materialize` itself: every existing report/query/command
      # caller keeps the wrapped shape it already depends on (Banking's
      # own `CustomerPortfolio` reads `payment[:amount][:cents]`, and
      # changing that out from under it would be a real breaking change,
      # not a bug fix). This is read_model_interpreter.rb's own opt-in,
      # used ONLY for a `group_by`-declared head's own rows — grouping
      # needs a real scalar to key by regardless, so a report already
      # asking for that gets the unwrap for free.
      def self.materialize_unwrapped(value)
        case value
        when self
          sole = value.value_object.sole_attribute
          return materialize_unwrapped(value[sole.name]) if sole

          # NOT `value.to_h` — `Value#to_h` materializes each field through
          # plain `materialize`, so a VO nested inside a multi-attribute VO
          # would already be a plain Hash by the time this method ever saw
          # it, and never reach the `when self` branch above. Read each
          # field straight off `value` instead, so recursion actually
          # happens through THIS method the whole way down.
          value.value_object.attributes.to_h { |attr| [attr.name, materialize_unwrapped(value[attr.name])] }
        when Array then value.map { |item| materialize_unwrapped(item) }
        when Hash then value.transform_values { |item| materialize_unwrapped(item) }
        else value
        end
      end

      def method_missing(name, *args)
        return @fields[name] if @fields.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @fields.key?(name) || super
      end
    end
  end
end
