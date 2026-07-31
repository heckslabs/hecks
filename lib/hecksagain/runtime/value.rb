require "json"
require_relative "../rendering"
module Hecksagain
  module Runtime
    class InvariantViolation < StandardError; end

    class Value
      def self.for(aggregate, name, value)
        attribute = aggregate.attribute(name)
        return value unless attribute

        for_attribute(aggregate, attribute, value)
      end

      def self.for_attribute(aggregate, attribute, value)
        return value if attribute.nil? || value.nil?
        return hydrate_entity_list(aggregate, attribute, value) if attribute.list?
        return value unless aggregate.respond_to?(:value_object)

        aggregate.value_object(attribute.type)
          .then do |value_object|
            return value if value.is_a?(self) && value.type_name == value_object&.hecks_name

            value_object ? build(value_object, fields_for(value_object, attribute.name, value)) : value
          end
      end

      def self.fields_for(value_object, name, value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)
        # Mutations may legitimately carry a value object into a differently
        # named value-object slot with the same declared fields (for example,
        # PositiveMoney into an Account's Money balance).  Rebuild the target
        # type from its state; callers at the public boundary still have to
        # supply an object rather than a scalar.
        return value.to_h if value.is_a?(self)

        raise TypeMismatch,
              "#{name} is a #{value_object.hecks_name} — pass its fields as an object, not #{Rendering.describe(value)}"
      end

      def self.build(value_object, fields)
        fields = value_object.attributes.each_with_object(fields.transform_keys(&:to_sym)) do |attribute, completed|
          completed[attribute.name] = attribute.default unless completed.key?(attribute.name) || attribute.default.nil?
        end
        admit_member(value_object, fields)
        check_numeric_fields(value_object, fields)
        value_object.invariants.each do |invariant|
          next if Bluebook::Expression::Evaluator.call(invariant.canonical, fields)

          raise InvariantViolation,
                "#{value_object.hecks_name} invariant violated — #{invariant.description} " \
                "(given #{canonical_fields(fields)})"
        end
        new(value_object, fields)
      end

      # A field declared Integer or Float must ARRIVE as one.
      #
      # Without this a String sails into a numeric field and the failure surfaces
      # later, inside a predicate, as `positive? expects a number, got "three"` —
      # an EvaluationError, which is NOT a domain refusal. So the runtime broke
      # where the domain should have said no, and the run contract recorded the
      # crash beside genuine refusals as though the domain had judged it.
      #
      # Checked BEFORE invariants, because an invariant reading a mistyped field
      # is exactly the thing that used to explode.
      NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze
      private_class_method def self.check_numeric_fields(value_object, fields)
        value_object.attributes.each do |attribute|
          expected = NUMERIC[attribute.type.to_s]
          next unless expected

          given = fields[attribute.name]
          next if given.nil? || given.is_a?(expected)

          raise TypeMismatch,
                "#{value_object.hecks_name}.#{attribute.name} expects #{attribute.type}, got #{Rendering.describe(given)}"
        end
      end

      def self.hydrate(aggregate, state)
        state.each_with_object({}) do |(name, value), hydrated|
          key       = name.to_sym
          attribute = aggregate.attribute(key)
          hydrated[key] = attribute ? for_attribute(aggregate, attribute, value) : value
        end
      end

      def self.hydrate_entity_list(aggregate, attribute, value)
        entity = aggregate.entities.find { |candidate| candidate.hecks_name == attribute.type.to_s }
        return value unless entity

        Array(value).map do |element|
          next element unless element.is_a?(Hash)

          element.each_with_object({}) do |(name, field_value), hydrated|
            key = name.to_sym
            field = entity.attribute(key)
            hydrated[key] = field ? for_attribute(aggregate, field, field_value) : field_value
          end
        end
      end

      # `Value.identifier` used to live here: hand it a one-field value object
      # and it opened it, so `identified_by :number` could pass for an identity
      # and the runtime would guess which field was meant. THAT GUESS IS GONE.
      # An identity names its field — `identified_by { number.value }` — and the
      # path is what reaches the scalar. A declaration that names no field is
      # refused when the bluebook loads, so nothing has to be unwrapped later.
      #
      # `scalar` below is a different job and stays: rendering a value object
      # into a column or a message, where there is no path to consult.

      # `Value.reference_id` lived here, opening a reference to find the id
      # inside it. A reference IS the id now — refused at the payload gate if it
      # arrives as anything else — so there is nothing left to open. The comment
      # it carried said retiring it meant changing how references are STORED ;
      # that is what happened.

      # A REFERENCE IS AN ID, SO AN OBJECT IS NOT ONE.
      #
      # Nothing coerces a reference — `for_attribute` misses on
      # "Reference<Account>", which is no value object's name, and hands the
      # argument straight through. That is why the wrapped form went in
      # unnoticed for as long as it did: there was no place it could be
      # refused, so whatever the first caller wrote became the shape.
      #
      # This is that place. It sits at the payload gate rather than inside
      # coercion because the sentence names the COMMAND, and `for_attribute`
      # never learns which command it is serving.
      #
      # An Array is deliberately not refused here. A reference is never a list
      # today, and inventing a rule for a shape the language cannot declare is
      # how decoration gets written.
      def self.refuse_object_reference(command, attribute, value)
        return unless attribute.reference?
        return unless value.is_a?(Hash) || value.is_a?(self)

        raise TypeMismatch,
              "#{command.hecks_name} refused — a reference is an id, and " \
              "#{attribute.name} arrived as an object#{known_by(attribute)}"
      end

      # "(Account is known by number)" — what to send instead. No article, on
      # purpose: "an Account" and "a Customer" differ by the target's first
      # letter, and both runtimes would have to agree on that rule to keep the
      # refusal byte-identical. Silent when the target is another chapter's,
      # where this runtime cannot see what it is known by.
      def self.known_by(attribute)
        target = attribute.type.resolve&.ir
        return "" unless target&.identified_by

        " (#{attribute.type.target_name} is known by #{target.identified_by})"
      end

      def self.scalar(value)
        return value unless value.is_a?(self)

        fields = value.to_h
        return fields.values.first if fields.size == 1

        raise TypeMismatch, "#{value.type_name} has multiple fields and cannot stand in for a scalar"
      end

      def self.from_identifier(aggregate, attribute, identifier)
        value_object = aggregate.value_object(attribute.type)
        return identifier unless value_object

        fields = value_object.attributes
        return build(value_object, { fields.first.name => identifier }) if fields.size == 1

        raise TypeMismatch, "#{value_object.hecks_name} is a composite identity — an identity must have exactly one field"
      end

      def self.admit_member(value_object, fields)
        return if value_object.members.empty?

        discriminant = value_object.attributes.first.name
        offered      = fields[discriminant]
        admitted     = value_object.members.map { |member| member[discriminant].to_s }
        return if admitted.include?(offered.to_s)

        raise InvariantViolation,
              "#{value_object.hecks_name} admits #{admitted.map(&:inspect).join(', ')} — got #{offered.inspect}"
      end

      def self.canonical_fields(fields)
        JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
      end

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
