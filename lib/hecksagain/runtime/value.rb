require "json"
module Hecksagain
  module Runtime
    class InvariantViolation < StandardError; end

    class Value
      def self.for(aggregate, name, value)
        value_object = declared_by(aggregate, name)
        return value unless value_object
        return value if value.nil?

        build(value_object, fields_for(value_object, name, value))
      end

      def self.declared_by(aggregate, name)
        attribute = aggregate.attribute(name)
        return nil unless attribute&.scalar?

        aggregate.value_object(attribute.type)
      end

      def self.fields_for(value_object, name, value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)

        only = value_object.attributes
        return { only.first.name => value } if only.size == 1

        raise TypeMismatch,
              "#{name} is a #{value_object.name}, which has " \
              "#{only.map { |a| a.name }.join(', ')} — pass those fields, not " \
              "#{value.inspect}. A scalar can only stand in for a value " \
              "object with exactly one field."
      end

      def self.build(value_object, fields)
        admit_member(value_object, fields)
        value_object.invariants.each do |invariant|
          next if Bluebook::Expression::Evaluator.call(invariant.canonical, fields)

          raise InvariantViolation,
                "#{value_object.name} invariant violated — #{invariant.description} " \
                "(given #{canonical_fields(fields)})"
        end
        fields
      end

      def self.admit_member(value_object, fields)
        return if value_object.members.empty?

        discriminant = value_object.attributes.first.name
        offered      = fields[discriminant]
        admitted     = value_object.members.map { |member| member[discriminant].to_s }
        return if admitted.include?(offered.to_s)

        raise InvariantViolation,
              "#{value_object.name} admits #{admitted.map(&:inspect).join(', ')} — got #{offered.inspect}"
      end

      def self.canonical_fields(fields)
        JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
      end

      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = fields
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
