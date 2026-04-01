module PizzasDomain
  class << self
    attr_accessor :event_bus, :command_bus, :current_role
    attr_reader :config

    def role_allows?(aggregate, action)
      return true unless current_role
      allowed = PORTS.dig(current_role.to_s, aggregate.to_s)
      return true unless allowed
      allowed.include?(action.to_s)
    end

    def boot(adapter: :memory)
      @current_role ||= "admin"
      @config = { adapter: adapter, booted_at: Time.now }
      @event_bus = Runtime::EventBus.new
      @command_bus = Runtime::CommandBus.new(event_bus: @event_bus)
      require_relative "lib/pizzas_domain/validations"
      Validations.rules = VALIDATIONS

      Pizza.repository = case adapter
        when :filesystem
          require_relative "lib/pizzas_domain/adapters/filesystem_repository"
          Adapters::FilesystemRepository.new("Pizza", Pizza)
        else Adapters::PizzaMemoryRepository.new
        end
      Pizza.event_bus = @event_bus
      Pizza.command_bus = @command_bus
      Order.repository = case adapter
        when :filesystem
          require_relative "lib/pizzas_domain/adapters/filesystem_repository"
          Adapters::FilesystemRepository.new("Order", Order)
        else Adapters::OrderMemoryRepository.new
        end
      Order.event_bus = @event_bus
      Order.command_bus = @command_bus

      Pizza::Commands::CreatePizza.repository = Pizza.repository
      Pizza::Commands::CreatePizza.event_bus = @event_bus
      Pizza::Commands::CreatePizza.command_bus = @command_bus
      Pizza::Commands::CreatePizza.aggregate_type = "Pizza"
      Pizza.define_singleton_method(:create_pizza) { |**attrs| Pizza::Commands::CreatePizza.call(**attrs) }
      Pizza::Commands::AddTopping.repository = Pizza.repository
      Pizza::Commands::AddTopping.event_bus = @event_bus
      Pizza::Commands::AddTopping.command_bus = @command_bus
      Pizza::Commands::AddTopping.aggregate_type = "Pizza"
      Pizza.define_singleton_method(:add_topping) { |**attrs| Pizza::Commands::AddTopping.call(**attrs) }
      Order::Commands::PlaceOrder.repository = Order.repository
      Order::Commands::PlaceOrder.event_bus = @event_bus
      Order::Commands::PlaceOrder.command_bus = @command_bus
      Order::Commands::PlaceOrder.aggregate_type = "Order"
      Order.define_singleton_method(:place_order) { |**attrs| Order::Commands::PlaceOrder.call(**attrs) }
      Order::Commands::CancelOrder.repository = Order.repository
      Order::Commands::CancelOrder.event_bus = @event_bus
      Order::Commands::CancelOrder.command_bus = @command_bus
      Order::Commands::CancelOrder.aggregate_type = "Order"
      Order.define_singleton_method(:cancel_order) { |**attrs| Order::Commands::CancelOrder.call(**attrs) }
      Pizza::Queries::ByDescription.repository = Pizza.repository
      Pizza.define_singleton_method(:by_description) { |*args| Pizza::Queries::ByDescription.call(*args) }
      Order::Queries::Pending.repository = Order.repository
      Order.define_singleton_method(:pending) { |*args| Order::Queries::Pending.call(*args) }
      Pizza.define_singleton_method(:find) { |id| repository.find(id) }
      Pizza.define_singleton_method(:all) { repository.all }
      Pizza.define_singleton_method(:count) { repository.count }
      Pizza.define_singleton_method(:where) { |**conds| Runtime::QueryBuilder.new(repository).where(**conds) }
      Order.define_singleton_method(:find) { |id| repository.find(id) }
      Order.define_singleton_method(:all) { repository.all }
      Order.define_singleton_method(:count) { repository.count }
      Order.define_singleton_method(:where) { |**conds| Runtime::QueryBuilder.new(repository).where(**conds) }

      Object.const_set(:Pizza, Pizza) unless Object.const_defined?(:Pizza)
      Object.const_set(:Order, Order) unless Object.const_defined?(:Order)
      self
    end

    def reboot(adapter: :memory)
      boot(adapter: adapter)
    end

    def on(event_name, &block)
      @event_bus.subscribe(event_name, &block)
    end

    def events
      @event_bus.events
    end

    def serve(port: 9292)
      require_relative "lib/pizzas_domain/server/domain_app"
      Server::DomainApp.new(self).start(port: port)
    end

    def domain_info
      {
        "Pizza" => { commands: ["CreatePizza", "AddTopping"], ports: { :admin => ["find", "all", "create_pizza", "add_topping"], :customer => ["find", "all"] }, count: Pizza.count },
        "Order" => { commands: ["PlaceOrder", "CancelOrder"], ports: { :admin => ["find", "all", "place_order", "cancel_order"], :customer => ["find", "all", "place_order"] }, count: Order.count }
      }
    end

    def policy_info
      []
    end
  end
end
