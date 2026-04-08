# Hecks::Runtime::SagaSetup
#
# Mixin that wires saga definitions as callable methods on the domain
# module at boot time. Each saga becomes a method named start_<saga_name>
# that accepts keyword arguments and executes the saga through SagaRunner.
#
#   class Runtime
#     include SagaSetup
#   end
#
module Hecks
  class Runtime
    # Hecks::Runtime::SagaSetup
    #
    # Wires saga definitions as start_<saga_name> methods on the domain module at boot time.
    #
    module SagaSetup
      include HecksTemplating::NamingHelpers
      private

      # Wires all sagas defined in the domain DSL as callable singleton
      # methods on the domain module.
      #
      # For each saga, creates a SagaRunner and defines a method named
      # start_<underscored_saga_name> (e.g., saga "OrderFulfillment"
      # becomes domain_mod.start_order_fulfillment(**attrs)).
      #
      # @return [void]
      def setup_sagas
        return unless @domain.respond_to?(:sagas)
        return if @domain.sagas.empty?

        @saga_store ||= SagaStore.new

        @domain.sagas.each do |saga|
          runner = SagaRunner.new(saga, @command_bus, @saga_store, @event_bus)
          method_name = :"start_#{bluebook_snake_name(saga.name)}"

          @mod.define_singleton_method(method_name) do |**attrs|
            runner.start(**attrs)
          end
        end
      end
    end
  end
end
