module Hecks
  module DSL

    # Hecks::DSL::EventBuilder
    #
    # DSL builder for explicit domain event declarations.
    # Used for events not inferred from commands (time-based, external, computed).
    #
    #   builder = EventBuilder.new("PolicyExpired")
    #   builder.attribute :policy_id, String
    #   event = builder.build
    #
    class EventBuilder
      include AttributeCollector
      include Describable

      def initialize(name)
        @name = name
        @attributes = []
      end

      def build
        BluebookModel::Behavior::BluebookEvent.new(
          name: @name,
          attributes: @attributes,
          description: @description
        )
      end
    end
  end
end
