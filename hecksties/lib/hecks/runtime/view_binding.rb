  # Hecks::ViewBinding
  #
  # Wires read model projections to the event bus at runtime. For each
  # read model, creates a module under the domain namespace with a .current
  # method that returns the projected state hash, and subscribes projection
  # procs to the event bus so state is updated as events are published.
  #
  #   ViewBinding.bind(view, event_bus, domain_mod)
  #   # After events are published:
  #   PizzasDomain::OrderSummary.current  # => { total_orders: 5 }
  #
module Hecks
  class ViewBinding
    extend HecksTemplating::NamingHelpers
    # Binds a view (read model) definition to the event bus and domain module.
    #
    # Creates a new anonymous module under the domain namespace (e.g.,
    # +PizzasDomain::OrderSummary+) with a thread-safe +.current+ method
    # that returns a duplicate of the current projected state.
    #
    # For each projection defined on the view (keyed by event name), subscribes
    # to that event on the bus. When an event fires, the projection proc is called
    # with the event and the current state hash, and the return value becomes the
    # new state. All state mutations are protected by a Mutex.
    #
    # @param view [Hecks::DomainModel::View] the view definition containing projections
    # @param event_bus [Hecks::EventBus] the event bus to subscribe projections to
    # @param mod [Module] the domain module to define the view constant under
    # @return [void]
    def self.bind(view, event_bus, mod)
      state = {}
      mutex = Mutex.new

      view_mod = Module.new do
        define_singleton_method(:current) { mutex.synchronize { state.dup } }
      end

      mod.const_set(domain_constant_name(view.name), view_mod)

      view.projections.each do |event_name, projection|
        event_bus.subscribe(event_name) do |event|
          mutex.synchronize do
            state = projection.call(event, state)
          end
        end
      end
    end
  end
end
