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
          # Explicit projections from DSL
          if agg.respond_to?(:projections) && !agg.projections.empty?
            agg.projections.each do |proj_ir|
              proj = Projection.new(
                event_handlers: proj_ir.event_handlers,
                queries: proj_ir.queries
              )
              @projections[proj_ir.name] = proj
              proj_ir.event_handlers.each_key do |event_name|
                @event_bus.subscribe(event_name) { |event| proj.apply(event) }
              end
            end
          end

          # Auto-projection for every aggregate — convention
          auto = Projection.new(event_handlers: {}, queries: {})
          @projections[agg.name] = auto
          # Subscribe to all Create/Update events for this aggregate
          agg.commands.each do |cmd|
            event_names = cmd.respond_to?(:event_names) ? cmd.event_names : []
            event_names.each do |evt_name|
              @event_bus.subscribe(evt_name) do |event|
                id = event.respond_to?(:aggregate_id) ? event.aggregate_id : "singleton"
                attrs = {}
                event.instance_variables.each do |ivar|
                  k = ivar.to_s.delete_prefix("@")
                  next if k == "aggregate_id" || k == "timestamp"
                  attrs[k.to_sym] = event.instance_variable_get(ivar)
                end
                auto.upsert(id, attrs) unless attrs.empty?
              end
            end
          end
        end
      end
    end
  end
end
