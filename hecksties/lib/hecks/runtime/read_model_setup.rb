# Hecks::Runtime::ReadModelSetup
#
# Mixin that wires read model projections to the event bus at boot time.
# Each read model becomes a module under the domain namespace with a
# .current method that returns projected state.
#
#   class Runtime
#     include ReadModelSetup
#   end
#
module Hecks
  class Runtime
    # Hecks::Runtime::ReadModelSetup
    #
    # Wires read model projections to the event bus at boot time so each read model has a .current method.
    #
    module ReadModelSetup
      private

      def setup_read_models
        return unless @domain.respond_to?(:views)

        @domain.views.each do |rm|
          ReadModelWiring.bind(rm, @event_bus, @mod)
        end
      end
    end
  end
end
