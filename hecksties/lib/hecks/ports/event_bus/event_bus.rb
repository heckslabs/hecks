module Hecks
  # Hecks::EventBus
  #
  # Simple in-process publish/subscribe event bus. Stores all published events
  # in an ordered log and notifies registered listeners by event class name.
  #
  # Supports two subscription modes:
  # - Named subscriptions via +subscribe(event_name)+ for specific event types
  # - Global subscriptions via +on_any+ for receiving every published event
  #
  # Part of the Ports layer. Used by the command runner and policy system to
  # decouple command execution from event handling and cross-cutting concerns.
  #
  # == Usage
  #
  #   bus = EventBus.new
  #   bus.subscribe("CreatedPizza") { |event| puts event.name }
  #   bus.on_any { |event| log(event) }
  #   bus.publish(pizza_created_event)
  #   bus.events  # => [#<CreatedPizza ...>]
  #   bus.clear   # empties the event log
  #
  class EventBus
      # @return [Array<Object>] ordered list of all published events
      attr_reader :events

      # Initializes an empty event bus with no listeners and no stored events.
      def initialize
        @listeners = Hash.new { |h, k| h[k] = [] }
        @global_listeners = []
        @events = []
      end

      # Registers a handler block to be called when the named event is published.
      #
      # Multiple handlers can be registered for the same event name; they are
      # called in registration order.
      #
      # @param event_name [String] the short class name of the event to listen for
      #   (e.g., "CreatedPizza"); matched against the last segment of the event's
      #   fully qualified class name
      # @yield [event] called each time a matching event is published
      # @yieldparam event [Object] the published domain event instance
      # @return [void]
      def subscribe(event_name, &handler)
        @listeners[event_name.to_s] << handler
      end

      # Registers a handler that receives every published event regardless of name.
      #
      # Used by +sends_to+ connections for outbound event forwarding between
      # bounded contexts.
      #
      # @yield [event] called for every published event
      # @yieldparam event [Object] the published domain event instance
      # @return [void]
      def on_any(&handler)
        @global_listeners << handler
      end

      # Publishes an event, appending it to the event log and notifying all
      # matching named listeners and all global listeners.
      #
      # Listener notification order: named listeners first (in registration order),
      # then global listeners (in registration order).
      #
      # @param event [Object] the domain event to publish; must have a class with
      #   a fully qualified name (the last segment is used for listener matching)
      # @return [void]
      def publish(event)
        @events << event
        event_name = Hecks::Utils.const_short_name(event)
        @listeners[event_name].each { |handler| handler.call(event) }
        @global_listeners.each { |handler| handler.call(event) }
      end

      # Clears the stored event log. Does not affect registered listeners.
      #
      # @return [void]
      def clear
        @events.clear
      end
  end
end
