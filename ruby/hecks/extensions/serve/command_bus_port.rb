module Hecks
  module HTTP
    # Hecks::HTTP::CommandBusPort
    #
    # Explicit HTTP adapter port that owns all dispatch between HTTP routes
    # and the domain. Mutations route through the CommandBus middleware
    # pipeline. Reads validate against a safety whitelist before calling
    # public methods on aggregate classes.
    #
    # Supports its own middleware layer (independent from CommandBus
    # middleware) that wraps every dispatch call. Port middleware fires
    # before the command reaches the bus.
    #
    # Usage:
    #   port = Hecks::HTTP::CommandBusPort.new(command_bus: bus)
    #   port.dispatch("CreatePizza", name: "Margherita")
    #   port.read(PizzaClass, "Pizza", :all)
    #
    class CommandBusPort
      # Methods that must never be callable via the read path.
      FORBIDDEN_READS = %i[
        eval system exec send __send__ instance_eval class_eval
        module_eval define_method remove_method
      ].freeze

      # Error raised when a read targets a forbidden method.
      class DispatchNotAllowed < StandardError; end

      # @param command_bus [Hecks::Commands::CommandBus] the bus for mutation dispatch
      def initialize(command_bus:)
        @command_bus = command_bus
        @middlewares = []
      end

      # Dispatch a mutation through port middleware, then the command bus.
      #
      # @param command_name [String] e.g. "CreatePizza"
      # @param attrs [Hash] keyword arguments for the command
      # @return [Object] the result from the command bus pipeline
      def dispatch(command_name, **attrs)
        run_middlewares(command_name, attrs) do
          @command_bus.dispatch(command_name, **attrs)
        end
      end

      # Execute a read against an aggregate class after safety validation.
      #
      # @param klass [Class] the aggregate class (e.g. PizzasDomain::Pizza)
      # @param agg_name [String] aggregate name for logging/context
      # @param method_name [Symbol] the method to call (e.g. :all, :find)
      # @param args [Array] positional arguments forwarded to the method
      # @return [Object] the method's return value
      # @raise [DispatchNotAllowed] if method_name is on the forbidden list
      def read(klass, agg_name, method_name, *args)
        sym = method_name.to_sym
        raise DispatchNotAllowed, "Forbidden read method: #{sym}" if FORBIDDEN_READS.include?(sym)

        klass.public_send(sym, *args)
      end

      # Register port-level middleware that wraps dispatch calls.
      #
      # @param name [Symbol, String] a label for the middleware
      # @yield [command_name, attrs, next_fn] the middleware logic
      # @yieldparam command_name [String] the command being dispatched
      # @yieldparam attrs [Hash] command attributes
      # @yieldparam next_fn [Proc] call to continue the chain
      # @return [void]
      def use(name, &block)
        @middlewares << { name: name, block: block }
      end

      private

      # Build and execute the port middleware chain around a final block.
      #
      # @param command_name [String] the command name for middleware context
      # @param attrs [Hash] the command attributes for middleware context
      # @yield the innermost handler (command bus dispatch)
      # @return [Object] the chain result
      def run_middlewares(command_name, attrs, &final)
        chain = @middlewares.reverse.reduce(final) do |next_fn, mw|
          -> { mw[:block].call(command_name, attrs, next_fn) }
        end
        chain.call
      end
    end
  end
end
