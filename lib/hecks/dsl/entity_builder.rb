module Hecks
  module DSL

    # Hecks::DSL::EntityBuilder
    #
    # DSL builder for sub-entity definitions within aggregates. Collects attributes
    # and invariants, then builds a DomainModel::Structure::Entity. Entities have
    # identity (UUID), are mutable, and use identity-based equality.
    #
    # Part of the DSL layer, nested under AggregateBuilder. The resulting entity
    # is embedded within its parent aggregate.
    #
    #   builder = EntityBuilder.new("LedgerEntry")
    #   builder.attribute :amount, Float
    #   builder.attribute :description, String
    #   builder.invariant("amount positive") { amount > 0 }
    #   entity = builder.build  # => #<Entity name="LedgerEntry" ...>
    #
    # Builds a DomainModel::Structure::Entity from DSL declarations.
    #
    # EntityBuilder collects attributes and invariants for a sub-entity that
    # lives within an aggregate boundary. Unlike value objects, entities have
    # their own identity (a UUID assigned at creation) and use identity-based
    # equality. They are mutable and can be independently referenced within
    # their parent aggregate.
    #
    # Includes AttributeCollector for the +attribute+, +list_of+, and
    # +reference_to+ DSL methods.
    class EntityBuilder
      Structure = DomainModel::Structure

      include AttributeCollector
      include Describable

      # Initialize a new entity builder with the given entity name.
      #
      # @param name [String] the entity type name (e.g. "LedgerEntry", "LineItem")
      def initialize(name)
        @name = name
        @attributes = []
        @invariants = []
      end

      # Define an invariant constraint on this entity.
      #
      # Invariants are boolean conditions that must always hold true for the
      # entity to be in a valid state. They are checked after mutations.
      #
      # @param message [String] human-readable description of the invariant
      # @yield block that returns true when the invariant holds, false when violated
      # @return [void]
      def invariant(message, &block)
        @invariants << Structure::Invariant.new(message: message, block: block)
      end

      # Build and return the DomainModel::Structure::Entity IR object.
      #
      # @return [DomainModel::Structure::Entity] the fully built entity IR object
      def build
        Structure::Entity.new(
          name: @name,
          attributes: @attributes,
          invariants: @invariants,
          description: @description
        )
      end
    end
  end
end
