module Hecks
  module BluebookModel
    module Structure

    # Hecks::BluebookModel::Structure::Entity
    #
    # Intermediate representation of a sub-entity within an aggregate. Entities
    # have identity (UUID), are mutable, and use identity-based equality -- unlike
    # value objects which are immutable and compared by attributes.
    #
    # Entities are owned by their parent aggregate and cannot exist independently.
    # They are always accessed through the aggregate root. Generated entity classes
    # include Hecks::Model, which provides identity, attribute accessors, and
    # invariant enforcement.
    #
    # Part of the BluebookModel IR layer. Built by EntityBuilder and consumed by
    # EntityGenerator to produce classes that include Hecks::Model.
    #
    #   entity = Entity.new(
    #     name: "LedgerEntry",
    #     attributes: [Attribute.new(name: :amount, type: Float)],
    #     invariants: [Invariant.new(message: "amount positive", block: proc { amount > 0 })]
    #   )
    #   entity.name        # => "LedgerEntry"
    #   entity.attributes  # => [#<Attribute ...>]
    #
    class Entity
      # @return [String] the PascalCase name of this entity (e.g., "LedgerEntry", "LineItem")
      attr_reader :name

      # @return [Array<Attribute>] the typed attributes of this entity. An implicit :id attribute
      #   (UUID) is added by the generator; these are the domain-specific fields.
      attr_reader :attributes

      # @return [Array<Invariant>] business rules that must hold true for this entity.
      #   Each invariant has a message and an optional block evaluated in the entity's context.
      attr_reader :invariants

      # Creates a new Entity IR node.
      #
      # @param name [String] PascalCase name of the entity (e.g., "LedgerEntry")
      # @param attributes [Array<Attribute>] the entity's typed attributes
      # @param invariants [Array<Invariant>] business rules enforced on this entity
      #
      # @return [Entity] a new Entity instance
      def initialize(name:, attributes: [], invariants: [], description: nil)
        @name = name
        @attributes = attributes
        @invariants = invariants
        @description = description
      end

      # @return [String, nil] human-readable description of this entity
      attr_reader :description
    end
    end
  end
end
