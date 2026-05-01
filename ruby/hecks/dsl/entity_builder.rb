module Hecks
  module DSL

    # Hecks::DSL::EntityBuilder
    #
    # DSL builder for sub-entity definitions within aggregates. Collects attributes
    # and invariants, then builds a BluebookModel::Structure::Entity. Entities have
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
    # Builds a BluebookModel::Structure::Entity from DSL declarations.
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
      Structure = BluebookModel::Structure
      Behavior  = BluebookModel::Behavior

      include AttributeCollector
      include Describable

      # Initialize a new entity builder with the given entity name.
      #
      # @param name [String] the entity type name (e.g. "LedgerEntry", "LineItem")
      def initialize(name)
        @name = name
        @attributes = []
        @invariants = []
        @commands = []
        @queries = []
        @lifecycle = nil
        @identified_by = nil
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

      # i111-J — entity blocks may declare commands, queries, lifecycle,
      # and identified_by the same way aggregates do. Dispatch addresses
      # them as `Aggregate.Entity.Command` (3-part) or as `Aggregate.Command`
      # when the bare name is unique among the parent's entities. Mirrors
      # the relevant slice of AggregateBuilder so the parity contract holds.

      # Define a command owned by this entity.
      #
      # @param name [String] the command name (e.g. "AddEntry")
      # @yield block evaluated in CommandBuilder context
      # @return [void]
      def command(name, &block)
        builder = CommandBuilder.new(name)
        builder.instance_eval(&block) if block
        @commands << builder.build
      end

      # Define a query owned by this entity. Mirrors AggregateBuilder's
      # QueryMethods : entities and aggregates use the same Behavior::Query
      # IR node so the canonical dump produces a uniform shape.
      #
      # @param name [String] the query name
      # @yield block implementing the query logic
      # @return [void]
      def query(name, &block)
        @queries << BluebookModel::Behavior::Query.new(name: name, block: block)
      end

      # Define a state-machine lifecycle on a field of this entity.
      #
      # @param field [Symbol] the state attribute (e.g. :status)
      # @param default [String] the initial state value
      # @yield block evaluated in LifecycleBuilder context
      # @return [void]
      def lifecycle(field, default:, &block)
        builder = LifecycleBuilder.new(field, default: default)
        builder.instance_eval(&block) if block
        @lifecycle = builder.build
      end

      # Declare the natural-key attribute used to identify a sub-record
      # of this entity within the parent aggregate's boundary.
      #
      # @param field [Symbol] the entity's natural primary key
      # @return [void]
      def identified_by(field)
        @identified_by = field.to_sym
      end

      # Build and return the BluebookModel::Structure::Entity IR object.
      #
      # @return [BluebookModel::Structure::Entity] the fully built entity IR object
      def build
        Structure::Entity.new(
          name: @name,
          attributes: @attributes,
          invariants: @invariants,
          description: @description,
          commands: @commands,
          queries: @queries,
          lifecycle: @lifecycle,
          identified_by: @identified_by
        )
      end
    end
  end
end
