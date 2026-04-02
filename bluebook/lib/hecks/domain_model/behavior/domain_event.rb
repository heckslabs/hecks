module Hecks
  module DomainModel
    module Behavior

    # Hecks::DomainModel::Behavior::DomainEvent
    #
    # Intermediate representation of a domain event -- a record that something
    # happened. Events are automatically inferred from commands by the
    # AggregateBuilder (CreatePizza -> CreatedPizza) and carry the same attributes.
    #
    # Part of the DomainModel IR layer. Consumed by EventGenerator to produce
    # frozen event classes with +occurred_at+ timestamps. Events are published on
    # the EventBus after successful command execution and can trigger reactive
    # policies and event subscribers.
    #
    #   event = DomainEvent.new(name: "CreatedPizza", attributes: [Attribute.new(name: :name, type: String)])
    #   event.name        # => "CreatedPizza"
    #   event.attributes  # => [#<Attribute name=:name>]
    #
    class DomainEvent
      # @return [String] PascalCase event name in past tense, e.g. "CreatedPizza"
      # @return [Array<Hecks::DomainModel::Structure::Attribute>] data attributes
      #   carried by the event, typically mirroring the originating command's attributes
      attr_reader :name, :attributes, :references, :description

      # Creates a new DomainEvent IR node.
      #
      # @param name [String] PascalCase past-tense event name (e.g. "CreatedPizza").
      #   Typically derived from a command name via {Command#inferred_event_name}.
      # @param attributes [Array<Hecks::DomainModel::Structure::Attribute>] data
      #   attributes carried by this event. Defaults to an empty array.
      # @param references [Array<Hecks::DomainModel::Structure::Reference>] references
      #   carried by this event. Defaults to an empty array.
      # @return [DomainEvent]
      def initialize(name:, attributes: [], references: [], description: nil)
        @name = Names.event_name(name)
        @attributes = attributes
        @references = references
        @description = description
      end
    end
    end
  end
end
