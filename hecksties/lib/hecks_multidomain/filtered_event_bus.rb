  # Hecks::FilteredEventBus
  #
  # Decorator around EventBus that enforces cross-domain event directionality.
  # Tags outgoing events with the publishing domain's +gem_name+, and filters
  # incoming events so only declared sources are received.
  #
  # When +allowed_sources+ is nil, all events pass through (open bus / backward-
  # compatible mode). When set, only events from those source domains (or events
  # with no source tag) are delivered to handlers.
  #
  # == How it works
  #
  # - +publish+ sets a +@_source_domain+ instance variable on the event before
  #   delegating to the inner bus. This tags the event with its origin domain.
  # - +subscribe+ and +on_any+ wrap handler blocks to check the source tag
  #   against the allowed sources list before invoking the original handler.
  #
  # == Usage
  #
  #   bus = FilteredEventBus.new(
  #     inner: shared_bus,
  #     domain_gem_name: "orders_domain",
  #     allowed_sources: ["inventory_domain"]
  #   )
  #   bus.publish(event)     # tags event with source "orders_domain"
  #   bus.subscribe("Foo") { |e| ... }  # only fires for events from inventory_domain
  #
module Hecks
  class FilteredEventBus
    # @return [Array<Object>] delegated to the inner bus's event log
    attr_reader :events

    # Creates a new FilteredEventBus wrapping an inner event bus.
    #
    # @param inner [Hecks::EventBus] the underlying event bus to delegate to
    # @param domain_gem_name [String] the name of this domain (used to tag
    #   published events with their source, e.g., "orders_domain")
    # @param allowed_sources [Array<String>, nil] list of domain gem names whose
    #   events this bus will accept; nil means accept all (open mode)
    def initialize(inner:, domain_gem_name:, allowed_sources: nil)
      @inner = inner
      @domain_gem_name = domain_gem_name
      @allowed_sources = allowed_sources&.map(&:to_s)
    end

    # Publishes an event, tagging it with this domain's gem name as the source.
    #
    # Sets the +@_source_domain+ instance variable on the event object before
    # delegating to the inner bus. This allows FilteredEventBus instances on
    # other domains to identify where the event originated.
    #
    # @param event [Object] the domain event to publish
    # @return [void]
    def publish(event)
      tagged = event.frozen? ? event.dup : event
      tagged.instance_variable_set(HecksTemplating::EventContract::SOURCE_ATTR, @domain_gem_name)
      @inner.publish(tagged)
    end

    # Registers a filtered handler for a specific event type.
    #
    # The handler is wrapped so it only fires for events from allowed sources
    # (or all events if +allowed_sources+ is nil).
    #
    # @param event_name [String] the short class name of the event to listen for
    # @yield [event] called when a matching, source-allowed event is published
    # @yieldparam event [Object] the published domain event instance
    # @return [void]
    def subscribe(event_name, &handler)
      filtered = wrap_handler(handler)
      @inner.subscribe(event_name, &filtered)
    end

    # Registers a filtered global handler that receives events from allowed sources.
    #
    # @yield [event] called for every source-allowed event
    # @yieldparam event [Object] the published domain event instance
    # @return [void]
    def on_any(&handler)
      filtered = wrap_handler(handler)
      @inner.on_any(&filtered)
    end

    # Returns the event log from the inner bus.
    #
    # @return [Array<Object>] all events published through the inner bus
    def events
      @inner.events
    end

    # Clears the event log on the inner bus.
    #
    # @return [void]
    def clear
      @inner.clear
    end

    private

    # Wraps a handler block with source-domain filtering logic.
    #
    # If +allowed_sources+ is nil (open mode), returns the handler unchanged.
    # Otherwise, returns a lambda that checks the event's +@_source_domain+
    # instance variable against the allowed list. Events with no source tag
    # (nil) are always allowed through.
    #
    # @param handler [Proc] the original handler block
    # @return [Proc] either the original handler or a filtering wrapper
    def wrap_handler(handler)
      return handler unless @allowed_sources

      sources = @allowed_sources
      ->(event) {
        source = event.instance_variable_get(HecksTemplating::EventContract::SOURCE_ATTR)
        handler.call(event) if source.nil? || sources.include?(source)
      }
    end
  end
end
