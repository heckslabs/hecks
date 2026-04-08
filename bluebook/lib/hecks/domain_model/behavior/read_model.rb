module Hecks
  module BluebookModel
    module Behavior

      # Hecks::BluebookModel::Behavior::ReadModel
      #
      # Intermediate representation of a read model -- an event-driven projection
      # that maintains a denormalized view of domain state. Each read model has a
      # name and a hash of projections mapping event names to transformation procs.
      #
      # When a domain event is published, the corresponding projection proc is called
      # with the event and the current projection state, producing an updated view.
      # Read models enable CQRS by separating the read side (optimized for queries)
      # from the write side (commands and aggregates).
      #
      # Part of the BluebookModel IR layer. Built by ReadModelBuilder, consumed by
      # ReadModelWiring at runtime to create queryable projections.
      #
      #   rm = ReadModel.new(
      #     name: "OrderSummary",
      #     projections: { "PlacedOrder" => proc { |event, state| state.merge(total: event.total) } }
      #   )
      #   rm.name         # => "OrderSummary"
      #   rm.projections  # => { "PlacedOrder" => #<Proc> }
      #
      class ReadModel
        # @return [String] PascalCase read model name (e.g. "OrderSummary")
        # @return [Hash{String => Proc}] mapping of event names to projection procs.
        #   Each proc receives (event, current_state) and returns the new state.
        attr_reader :name, :projections, :description

        # Creates a new ReadModel IR node.
        #
        # @param name [String] PascalCase read model name (e.g. "OrderSummary")
        # @param projections [Hash{String => Proc}] mapping of domain event names to
        #   transformation procs. Each proc receives two arguments: the event object
        #   and the current projection state, and must return the updated state.
        #   Defaults to an empty hash.
        # @return [ReadModel]
        def initialize(name:, projections: {}, description: nil)
          @name = name
          @projections = projections.transform_keys { |k| Names.event_name(k) }
          @description = description
        end
      end
    end
  end
end
