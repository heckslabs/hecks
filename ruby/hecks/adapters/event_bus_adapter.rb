# Hecks::Adapters::EventBusAdapter
#
# Adapter that provides real behavior for the EventBus aggregate
# from the Spec chapter. Wires Subscribe, Publish, and Clear
# commands to the runtime's actual event bus.
#
#   app.adapt("EventBus", Hecks::Adapters::EventBusAdapter)
#   app.run("Subscribe", event_name: "PizzaCreated")
#   app.run("Publish", event: some_event)
#   app.run("Clear")
#
module Hecks
  module Adapters
    # Hecks::Adapters::EventBusAdapter
    #
    # Command adapter for EventBus — delegates to the runtime's real event bus.
    #
    module EventBusAdapter
      def self.subscribe(command:, app:)
        event_name = command.respond_to?(:event_name) ? command.event_name : nil
        app.event_bus.subscribe(event_name.to_s) {} if event_name
      end

      def self.publish(command:, app:)
        event = command.respond_to?(:event) ? command.event : nil
        app.event_bus.publish(event) if event
      end

      def self.clear(command:, app:)
        app.event_bus.clear
      end
    end
  end
end
