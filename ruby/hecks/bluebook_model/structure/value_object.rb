module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::ValueObject
    #
    # Intermediate representation of a DDD value object -- an immutable object
    # defined entirely by its attributes, with no identity. Value objects can
    # also carry invariants (runtime constraints).
    #
    # Value objects differ from entities in two key ways:
    # 1. They have no identity -- two value objects with the same attributes are equal
    # 2. They are immutable -- once created, their attributes cannot change
    #
    # Generated value object classes are frozen after initialization and use
    # attribute-based equality (==). They include Hecks::Model with the
    # value_object flag set.
    #
    # Part of the BluebookModel IR layer. Built by ValueObjectBuilder and consumed
    # by ValueObjectGenerator to produce frozen, equality-by-value classes.
    #
    #   vo = ValueObject.new(
    #     name: "Address",
    #     attributes: [Attribute.new(name: :street, type: String)],
    #     invariants: [Invariant.new(message: "street required", block: proc { !street.nil? })]
    #   )
    #   vo.name        # => "Address"
    #   vo.attributes  # => [#<Attribute ...>]
    #   vo.invariants  # => [#<Invariant ...>]
    #
    class ValueObject
      # @return [String] the PascalCase name of this value object (e.g., "Address", "Money", "DateRange")
      attr_reader :name

      # @return [Array<Attribute>] the typed attributes that define this value object.
      #   Two value objects with identical attribute values are considered equal.
      attr_reader :attributes

      # @return [Array<Invariant>] business rules that must hold true for this value object.
      #   Evaluated during construction; if any invariant fails, the object cannot be created.
      attr_reader :invariants

      # Creates a new ValueObject IR node.
      #
      # @param name [String] PascalCase name of the value object (e.g., "Address", "Money")
      # @param attributes [Array<Attribute>] the attributes that define this value object
      # @param invariants [Array<Invariant>] business rules enforced at construction time
      #
      # @return [ValueObject] a new ValueObject instance
      def initialize(name:, attributes: [], invariants: [], description: nil)
        @name = name
        @attributes = attributes
        @invariants = invariants
        @description = description
      end

      # @return [String, nil] human-readable description of this value object
      attr_reader :description
    end
    end
  end
end
