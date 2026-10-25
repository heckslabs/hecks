require_relative "value"

module Hecks
  module Runtime
    # A field of an aggregate's head that holds one String, Integer or Float: the lifecycle field,
    # or an attribute whose value object has a single field of one of those types. A store can
    # read such a field as one SQL value, and a bulk run's one-statement form (ADR 0129) compiles
    # only reads and writes of these.
    class ScalarField
      # Each primitive a scalar field may hold, and the type a compiled operand carries for it.
      PRIMITIVE_TYPES = { "Integer" => :integer, "Float" => :float, "String" => :string }.freeze

      # @return [String] the field's name, which is its column's
      attr_reader :name

      # @return [String, nil] the value object's one field, nil for the lifecycle field
      attr_reader :member

      # @return [Symbol] `:integer`, `:float` or `:string`
      attr_reader :type

      # The scalar field `name` names on `aggregate`, or nil when it is not one.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose head holds the field
      # @param name [String, Symbol] the field's name
      # @return [Runtime::ScalarField, nil] the field, or nil when it holds anything else
      def self.of(aggregate, name)
        return new(name: name.to_s, member: nil, type: :string, writable: false) if aggregate.lifecycle_field.to_s == name.to_s

        attribute = aggregate.attribute(name.to_s)
        attribute && attribute_field(aggregate, attribute)
      end

      # @param name [String] the field's name
      # @param member [String, nil] the value object's one field
      # @param type [Symbol] the type the field holds
      # @param writable [Boolean] whether no invariant, pattern or closed set guards it
      def initialize(name:, member:, type:, writable:)
        @name = name
        @member = member
        @type = type
        @writable = writable
      end

      # @return [Boolean] whether the field is the lifecycle field, held as bare text
      def lifecycle? = member.nil?

      # @return [Boolean] whether a statement may write the field without a check Ruby makes
      def writable? = @writable

      class << self
        private

        def attribute_field(aggregate, attribute)
          return nil if attribute.list? || attribute.reference?

          shape = Value.value_object_for(aggregate, attribute.type)
          inner = shape&.sole_attribute
          type = primitive_type(inner)
          type && new(name: attribute.name.to_s, member: inner.name.to_s, type: type,
                      writable: unguarded?(attribute, shape, inner))
        end

        def primitive_type(inner) = inner && !inner.list? && PRIMITIVE_TYPES[inner.type.to_s]

        def unguarded?(attribute, shape, inner)
          [attribute, inner].all? { |field| field.pattern.nil? && field.admits.nil? } &&
            shape.invariants.empty? && shape.members.empty?
        end
      end
    end
  end
end
