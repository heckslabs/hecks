module Hecks
  module DomainModel
    module Behavior

    # Hecks::DomainModel::Behavior::EventSubscriber
    #
    # Intermediate representation of a DSL-defined event subscriber -- an
    # arbitrary code block that fires when a named event is published.
    # Unlike reactive policies (which must trigger a command), subscribers
    # can run any code: logging, notifications, cross-aggregate side effects.
    #
    # Subscribers are registered on the EventBus at boot time. When an event
    # matching +event_name+ is published, the +block+ is called with the event
    # as its argument. The +async+ flag hints to the runtime whether the
    # subscriber should be dispatched synchronously or asynchronously.
    #
    # Part of the DomainModel IR layer. Built by AggregateBuilder#on_event
    # and consumed by SubscriberGenerator to produce subscriber classes.
    #
    #   sub = EventSubscriber.new(
    #     name: "OnCreatedPizza",
    #     event_name: "CreatedPizza",
    #     block: proc { |event| puts event.name },
    #     async: false
    #   )
    #
    class EventSubscriber
      # @return [String] unique name for this subscriber, typically "On<EventName>"
      # @return [String] the domain event name this subscriber listens for
      # @return [Proc] the callable invoked when the event fires; receives the event object
      # @return [Boolean] whether this subscriber should run asynchronously
      attr_reader :name, :event_name, :block, :async

      # Creates a new EventSubscriber IR node.
      #
      # @param name [String] unique subscriber name (e.g. "OnCreatedPizza")
      # @param event_name [String] domain event name to listen for (e.g. "CreatedPizza")
      # @param block [Proc] callable invoked when the event fires; receives the
      #   event object as its single argument
      # @param async [Boolean] if true, the runtime should dispatch this subscriber
      #   asynchronously (e.g. via a background job). Defaults to false.
      # @return [EventSubscriber]
      def initialize(name:, event_name:, block:, async: false)
        @name = name
        @event_name = Names.event_name(event_name)
        @block = block
        @async = async
      end
    end
    end
  end
end
