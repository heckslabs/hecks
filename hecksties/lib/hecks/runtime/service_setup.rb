  # Hecks::ServiceSetup
  #
  # Wires domain services onto the domain module as callable class methods.
  # Each service gets a method on the module (e.g., Banking.transfer_money)
  # that instantiates the service with its attributes and runs the call body.
  # The call body has access to `dispatch` for orchestrating commands.
  #
  #   ServiceSetup.bind(domain, mod, command_bus)
  #   Banking.transfer_money(source_id: "abc", target_id: "xyz", amount: 500)
  #
module Hecks
  module ServiceSetup
    extend HecksTemplating::NamingHelpers
    # Binds all domain services as singleton methods on the domain module.
    #
    # Iterates through +domain.services+ and wires each one as a callable
    # method on +mod+.
    #
    # @param domain [Hecks::DomainModel::Domain] the domain definition containing service declarations
    # @param mod [Module] the domain module to define service methods on (e.g., +BankingDomain+)
    # @param command_bus [Hecks::CommandBus] the command bus for dispatching commands within service bodies
    # @return [void]
    def self.bind(domain, mod, command_bus)
      domain.services.each do |svc|
        wire_service(svc, mod, command_bus)
      end
    end

    # Wires a single service as a singleton method on the domain module.
    #
    # Creates a method named after the underscored service name that:
    # 1. Builds a +ServiceContext+ with the command bus, declared attribute names, and caller-provided values
    # 2. Evaluates the service's call body within that context
    # 3. Returns the accumulated results array from all dispatched commands
    #
    # @param svc [Hecks::DomainModel::Service] the service definition from the DSL
    # @param mod [Module] the domain module to define the method on
    # @param command_bus [Hecks::CommandBus] the command bus for the service context
    # @return [void]
    def self.wire_service(svc, mod, command_bus)
      method_name = domain_snake_name(svc.name).to_sym
      call_body = svc.call_body
      attr_names = svc.attributes.map(&:name)

      mod.define_singleton_method(method_name) do |**attrs|
        ctx = ServiceContext.new(command_bus, attr_names, attrs)
        ctx.instance_eval(&call_body) if call_body
        ctx.results
      end
    end
  end

  # Execution context for a service call body. Provides +dispatch+
  # and attribute readers so the block can orchestrate commands.
  #
  # Each attribute declared on the service becomes an instance variable
  # and a reader method, so the call body can reference them by name.
  # The +dispatch+ method sends commands through the command bus and
  # accumulates results.
  #
  #   # Inside a service call body:
  #   dispatch(:CreateTransfer, source_id: source_id, amount: amount)
  #
  class ServiceContext
    # @return [Array<Object>] accumulated results from all +dispatch+ calls
    attr_reader :results

    # Creates a new service execution context.
    #
    # @param command_bus [Hecks::CommandBus] the command bus to dispatch commands through
    # @param attr_names [Array<String, Symbol>] the names of attributes declared on the service
    # @param attrs [Hash{Symbol => Object}] the actual attribute values passed by the caller
    def initialize(command_bus, attr_names, attrs)
      @command_bus = command_bus
      @results = []
      attr_names.each do |name|
        instance_variable_set(:"@#{name}", attrs[name])
        define_singleton_method(name) { instance_variable_get(:"@#{name}") }
      end
    end

    # Dispatches a command through the command bus and records the result.
    #
    # @param command_name [Symbol, String] the name of the command to dispatch
    # @param attrs [Hash] keyword arguments to pass to the command
    # @return [Object] the result of the command execution
    def dispatch(command_name, **attrs)
      result = @command_bus.dispatch(command_name, **attrs)
      @results << result
      result
    end
  end
end
