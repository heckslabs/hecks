# Hecks::EventSourcing::ProcessManager
#
# Event-driven state machine that coordinates multi-step business processes.
# Listens for events, looks up or creates process instances by correlation ID,
# and transitions them through states. Each transition can dispatch commands.
#
# == Usage
#
#   pm = ProcessManager.new(name: "OrderFulfillment", store: SagaStore.new)
#   pm.on("OrderPlaced", correlate: :order_id, transition: { nil => :started }) do |event, instance|
#     { commands: ["ReserveInventory"] }
#   end
#   pm.on("InventoryReserved", correlate: :order_id, transition: { started: :reserved })
#   pm.on("PaymentReceived", correlate: :order_id, transition: { reserved: :completed })
#
#   pm.handle(event)  # drives the state machine
#
class Hecks::EventSourcing::ProcessManager
  Handler = Struct.new(:event_type, :correlate, :transition, :action, keyword_init: true)

  # @return [String] the process manager name
  attr_reader :name

  # @return [Hecks::SagaStore] the backing store for process instances
  attr_reader :store

  # @param name [String] the process manager name
  # @param store [Hecks::SagaStore] the store for process instances
  def initialize(name:, store:)
    @name = name
    @store = store
    @handlers = {}
  end

  # Register a handler for an event type with a state transition.
  #
  # @param event_type [String] the event name to handle
  # @param correlate [Symbol] the event attribute used as correlation ID
  # @param transition [Hash{Symbol,nil => Symbol}] from_state => to_state
  # @yield [event, instance] optional action block
  # @return [void]
  def on(event_type, correlate:, transition:, &action)
    @handlers[event_type.to_s] = Handler.new(
      event_type: event_type.to_s,
      correlate: correlate,
      transition: transition,
      action: action
    )
  end

  # Handle an incoming event: look up or create instance, apply transition.
  #
  # @param event [Object] the domain event; must respond to the correlate attribute
  # @return [Hash, nil] the updated instance, or nil if no handler matches
  def handle(event)
    event_type = Hecks::Utils.const_short_name(event)
    handler = @handlers[event_type]
    return nil unless handler

    correlation_id = event.respond_to?(handler.correlate) ? event.send(handler.correlate) : event_data_value(event, handler.correlate)
    return nil unless correlation_id

    instance = @store.find(correlation_id) || new_instance(correlation_id)
    from, to = handler.transition.first
    current_state = instance[:state]

    return instance unless state_matches?(current_state, from)

    instance[:state] = to
    instance[:handled_events] << event_type
    result = handler.action&.call(event, instance) || {}
    instance[:pending_commands] = result[:commands] || []
    @store.save(correlation_id, instance)
    instance
  end

  # Subscribe this process manager to an event bus.
  #
  # @param event_bus [Hecks::EventBus] the bus to listen on
  # @return [void]
  def subscribe_to(event_bus)
    @handlers.each_key do |event_type|
      event_bus.subscribe(event_type) { |event| handle(event) }
    end
  end

  private

  def new_instance(correlation_id)
    { correlation_id: correlation_id, state: nil, handled_events: [], pending_commands: [] }
  end

  def state_matches?(current, from)
    from.nil? ? current.nil? : current == from
  end

  def event_data_value(event, key)
    return nil unless event.respond_to?(key)
    event.send(key)
  end
end
