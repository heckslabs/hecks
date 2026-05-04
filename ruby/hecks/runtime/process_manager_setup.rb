# Hecks::Runtime::ProcessManagerSetup
#
# Mixin that wires process_manager declarations from the bluebook DSL
# into live Hecks::EventSourcing::ProcessManager instances at boot time.
# Each declared PM becomes a runtime instance subscribed to the event
# bus, with its handlers (event_type + transition + action proc) bound.
#
#   class Runtime
#     include ProcessManagerSetup
#   end
#
# Pairs with Phase 1's process_manager_builder.rb (DSL parser → IR) and
# Phase 3's Rust parse_process_manager (parity). Together they close
# the bluebook → IR → runtime arc for the new keyword.
#
module Hecks
  class Runtime
    # Hecks::Runtime::ProcessManagerSetup
    #
    # Walks @domain.process_managers, instantiates one runtime PM per
    # IR node, binds every handler, subscribes each to @event_bus.
    # Stores the bound instances on @process_managers for inspection.
    #
    module ProcessManagerSetup
      private

      # Wire all process_managers declared in the domain DSL.
      #
      # No-op if the domain doesn't carry process_managers (older IR
      # before Phase 1) or the collection is empty. The synthetic test
      # at spec/hecks/runtime/process_manager_setup_spec.rb exercises
      # both paths.
      #
      # @return [void]
      def setup_process_managers
        @process_managers = []
        return unless @domain.respond_to?(:process_managers)
        return if @domain.process_managers.nil? || @domain.process_managers.empty?

        @saga_store ||= SagaStore.new

        @domain.process_managers.each do |pm_ir|
          pm = Hecks::EventSourcing::ProcessManager.new(
            name: pm_ir.name,
            store: @saga_store
          )
          bind_pm_handlers(pm, pm_ir)
          pm.subscribe_to(@event_bus)
          @process_managers << pm
        end
      end

      # Translate each IR Handler (event_type, transition, action) into
      # a runtime pm.on(...) call. The IR factors correlates_by once per
      # PM ; the runtime API takes it per-handler — thread it here.
      #
      # @param pm [Hecks::EventSourcing::ProcessManager]
      # @param pm_ir [Hecks::BluebookModel::Behavior::ProcessManager]
      # @return [void]
      def bind_pm_handlers(pm, pm_ir)
        pm_ir.handlers.each do |handler|
          pm.on(
            handler.event_type,
            correlate: pm_ir.correlates_by,
            transition: handler.transition,
            &handler.action
          )
        end
      end
    end
  end
end
