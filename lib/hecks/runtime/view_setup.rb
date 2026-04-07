module Hecks
  class Runtime
    # Hecks::Runtime::ViewSetup
    #
    # Mixin that wires view projections to the event bus at boot time.
    # Each view becomes a module under the domain namespace with a
    # .current method that returns projected state.
    #
    #   class Runtime
    #     include ViewSetup
    #   end
    #
    module ViewSetup
      private

      # Wires all view (read model) projections defined in the domain DSL.
      #
      # Iterates through +@domain.views+ and delegates to +ViewBinding.bind+
      # for each one, which creates the view module under the domain namespace
      # and subscribes projection procs to the event bus.
      #
      # Returns immediately if the domain does not respond to +views+
      # (backward compatibility with older domain definitions).
      #
      # @return [void]
      def setup_views
        return unless @domain.respond_to?(:views)

        @domain.views.each do |v|
          ViewBinding.bind(v, @event_bus, @mod)
        end
      end
    end
  end
end
