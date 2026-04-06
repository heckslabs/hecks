  # Hecks::CrossDomainView
  #
  # An event-driven read model that projects events from multiple bounded
  # contexts into a single in-memory state. Subscribes to the shared event
  # bus and applies projection functions as events arrive.
  #
  # Each projection is a named function that receives the event and the current
  # state, and returns the new state. State is accumulated as a Hash that grows
  # as events are processed. The view can be reset to its initial empty state.
  #
  # == Lifecycle
  #
  # 1. Create the view with projections via a DSL block
  # 2. Subscribe it to an event bus (typically the shared cross-domain bus)
  # 3. As events are published, projections update the state
  # 4. Query +state+ at any time for the current read model
  #
  # == Usage
  #
  #   view = Hecks.cross_domain_view "RiskDashboard" do
  #     project("RegisteredModel") { |e, s| s.merge(total: (s[:total] || 0) + 1) }
  #     project("ReportedIncident") { |e, s| s.merge(incidents: (s[:incidents] || 0) + 1) }
  #   end
  #
  #   view.state  # => { total: 5, incidents: 2 }
  #   view.reset  # => clears state back to {}
  #
module Hecks
  class CrossDomainView
    # @return [String] the name of this view (e.g., "RiskDashboard")
    attr_reader :name

    # @return [Hash] the current accumulated state from all applied projections
    attr_reader :state

    # Creates a new cross-domain view with an optional DSL block for defining projections.
    #
    # @param name [String] a descriptive name for this view
    # @yield optional block evaluated in the context of the view instance to define
    #   projections via +project+
    def initialize(name, &block)
      @name = name
      @projections = {}
      @state = {}
      instance_eval(&block) if block
    end

    # Registers a projection function for a specific event type.
    #
    # The block receives the event and the current state, and must return
    # the new state (typically via +Hash#merge+).
    #
    # @param event_name [String] the short class name of the event to project
    #   (e.g., "RegisteredModel", matching the last segment of the event class name)
    # @yield [event, state] called when a matching event is applied
    # @yieldparam event [Object] the domain event instance
    # @yieldparam state [Hash] the current accumulated state
    # @yieldreturn [Hash] the new state after applying this projection
    # @return [void]
    def project(event_name, &block)
      @projections[event_name] = block
    end

    # Subscribes this view to an event bus for automatic projection.
    #
    # Registers a listener for each projection's event name. When a matching
    # event is published on the bus, the projection is applied via +apply+.
    #
    # @param event_bus [Hecks::EventBus, Hecks::FilteredEventBus, nil] the event bus
    #   to subscribe to; does nothing if nil
    # @return [void]
    def subscribe(event_bus)
      return unless event_bus
      @projections.each_key do |event_name|
        event_bus.subscribe(event_name) do |event|
          apply(event)
        end
      end
    end

    # Applies a domain event to the view's state using the matching projection.
    #
    # Extracts the event's short class name and looks up the corresponding
    # projection function. If found, calls it with the event and current state,
    # and replaces the state with the return value.
    #
    # @param event [Object] the domain event to apply; its class name (last segment)
    #   is used to find the matching projection
    # @return [void]
    def apply(event)
      event_name = Hecks::Utils.const_short_name(event)
      projection = @projections[event_name]
      @state = projection.call(event, @state) if projection
    end

    # Resets the view's state to an empty Hash.
    #
    # @return [Hash] the empty state
    def reset
      @state = {}
    end
  end
end
