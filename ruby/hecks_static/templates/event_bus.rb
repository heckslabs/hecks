# __DOMAIN_MODULE__::Runtime::EventBus
#
# In-process publish/subscribe event bus. Stores published events in an
# ordered log and notifies registered listeners by event class name.
# Supports named subscriptions and global (on_any) listeners.

module __DOMAIN_MODULE__
  module Runtime
    class EventBus
      attr_reader :events

      def initialize
        @listeners = Hash.new { |h, k| h[k] = [] }
        @global_listeners = []
        @events = []
      end

      def subscribe(event_name, &handler)
        @listeners[event_name.to_s] << handler
      end

      def on_any(&handler)
        @global_listeners << handler
      end

      def publish(event)
        @events << event
        event_name = event.class.name.split("::").last
        @listeners[event_name].each { |handler| handler.call(event) }
        @global_listeners.each { |handler| handler.call(event) }
      end

      def clear
        @events.clear
      end
    end
  end
end
