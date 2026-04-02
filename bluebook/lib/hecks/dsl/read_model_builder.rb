module Hecks
  module DSL

    # Hecks::DSL::ReadModelBuilder
    #
    # DSL builder for read model definitions. Collects event projections
    # and builds a DomainModel::Behavior::ReadModel. Each projection maps
    # an event name to a proc that transforms state.
    #
    #   builder = ReadModelBuilder.new("OrderSummary")
    #   builder.project("PlacedOrder") { |event, state| state.merge(total: event.quantity) }
    #   rm = builder.build  # => #<ReadModel name="OrderSummary" ...>
    #
    # Builds a DomainModel::Behavior::ReadModel from projection declarations.
    #
    # ReadModelBuilder defines a denormalized read-side view that is built by
    # applying projection functions to domain events. Each projection maps an
    # event name to a block that receives the event and current state, returning
    # the updated state. Multiple projections can be defined for different events.
    #
    # Read models are defined at the domain level via +DomainBuilder#view+ and
    # provide optimized query paths separate from the write-side aggregates.
    class ReadModelBuilder
      Behavior = DomainModel::Behavior

      include Describable

      # Initialize a new read model builder with the given view name.
      #
      # @param name [String] the read model name (e.g. "OrderSummary", "AccountBalance")
      def initialize(name)
        @name = name
        @projections = {}
      end

      # Define a projection that applies an event to the read model state.
      #
      # Each projection handles one event type. The block receives the event
      # and current state, and must return the new state. Projections are
      # applied in order as events arrive.
      #
      # @param event_name [String, Symbol] the domain event name to project
      # @yield [event, state] block that computes the new state
      # @yieldparam event [Object] the domain event being projected
      # @yieldparam state [Object] the current read model state
      # @yieldreturn [Object] the updated read model state
      # @return [void]
      #
      # @example
      #   project("PlacedOrder") { |event, state| state.merge(total: event.quantity) }
      def project(event_name, &block)
        @projections[event_name.to_s] = block
      end

      # Build and return the DomainModel::Behavior::ReadModel IR object.
      #
      # @return [DomainModel::Behavior::ReadModel] the fully built read model IR object
      def build
        Behavior::ReadModel.new(
          name: @name,
          projections: @projections,
          description: @description
        )
      end
    end
  end
end
