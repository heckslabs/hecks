# Hecks::BluebookModel::Structure::Projection
#
# Intermediate representation of a CQRS read model projection.
# A projection subscribes to domain events and maintains a
# denormalized in-memory data set optimized for queries. Built
# by ProjectionBuilder and consumed by the runtime layer.
#
#   projection = Projection.new(
#     name: "PizzaMenu",
#     event_handlers: { "CreatedPizza" => ->(event) { ... } },
#     queries: { "Popular" => ->(data) { ... } }
#   )
#   projection.event_handlers.keys  # => ["CreatedPizza"]
#
module Hecks
  module BluebookModel
    module Structure
      class Projection
        # @return [String] PascalCase name of this projection (e.g., "PizzaMenu")
        attr_reader :name

        # @return [Hash{String => Proc}] event name to handler proc mapping
        attr_reader :event_handlers

        # @return [Hash{String => Proc}] query name to filter proc mapping
        attr_reader :queries

        # Creates a new Projection IR node.
        #
        # @param name [String] PascalCase projection name
        # @param event_handlers [Hash{String => Proc}] event handlers keyed by event name
        # @param queries [Hash{String => Proc}] named queries keyed by query name
        # @return [Projection]
        def initialize(name:, event_handlers: {}, queries: {})
          @name = name
          @event_handlers = event_handlers
          @queries = queries
        end
      end
    end
  end
end
