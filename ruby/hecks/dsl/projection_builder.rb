# Bootstrap: Projection IR must be loaded before ProjectionBuilder
# since build creates Projection instances at DSL eval time.
require "hecks/bluebook_model/structure/projection"

# Hecks::DSL::ProjectionBuilder
#
# DSL builder for CQRS read model projections within an aggregate.
# Collects event handlers and named queries, then builds a
# BluebookModel::Structure::Projection IR object.
#
#   builder = ProjectionBuilder.new("PizzaMenu")
#   builder.on("CreatedPizza") { |event| upsert(event.aggregate_id, name: event.name) }
#   builder.query("Popular") { select { |_id, row| row[:topping_count] > 3 } }
#   projection = builder.build
#
module Hecks
  module DSL
    class ProjectionBuilder
      # @param name [String] PascalCase projection name
      def initialize(name)
        @name = name
        @event_handlers = {}
        @queries = {}
      end

      # Register an event handler for this projection.
      #
      # @param event_name [String] the domain event name to subscribe to
      # @yield [event] block called when the event is published
      # @return [void]
      def on(event_name, &block)
        @event_handlers[event_name.to_s] = block
      end

      # Register a named query on this projection.
      #
      # @param name [String] the query name
      # @yield block evaluated in the projection runtime context
      # @return [void]
      def query(name, &block)
        @queries[name.to_s] = block
      end

      # Build the Projection IR object from collected handlers and queries.
      #
      # @return [BluebookModel::Structure::Projection]
      def build
        BluebookModel::Structure::Projection.new(
          name: @name,
          event_handlers: @event_handlers,
          queries: @queries
        )
      end
    end
  end
end
