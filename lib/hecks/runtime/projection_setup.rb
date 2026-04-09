# Hecks::Runtime::ProjectionSetup
#
# Mixin that wires CQRS read model projections to the event bus
# at boot time. For each aggregate with projections, creates
# Runtime::Projection instances and subscribes them to events.
#
#   class Runtime
#     include ProjectionSetup
#   end
#   # After boot:
#   runtime.projection("PizzaMenu")
#
module Hecks
  class Runtime
    module ProjectionSetup
      # Look up a projection by name.
      #
      # @param name [String] the projection name (e.g., "PizzaMenu")
      # @return [Projection, nil] the projection instance or nil
      def projection(name)
        @projections ||= {}
        @projections[name.to_s]
      end

      private

      # Wire all projections from domain aggregates to the event bus.
      # Creates Projection runtime instances and subscribes each
      # event handler to the event bus.
      #
      # @return [void]
      def setup_projections
        @projections = {}

        @domain.aggregates.each do |agg|
          next unless agg.respond_to?(:projections)
          next if agg.projections.empty?

          agg.projections.each do |proj_ir|
            proj = Projection.new(
              event_handlers: proj_ir.event_handlers,
              queries: proj_ir.queries
            )
            @projections[proj_ir.name] = proj

            proj_ir.event_handlers.each_key do |event_name|
              @event_bus.subscribe(event_name) do |event|
                proj.apply(event)
              end
            end
          end
        end
      end
    end
  end
end
