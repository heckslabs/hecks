# __DOMAIN_MODULE__::Runtime::CommandBus
#
# Dispatches commands through a middleware pipeline. Each middleware wraps
# the next, like Rack middleware for commands. Middleware receives the
# command and a next_handler proc -- call it to continue the chain.

module __DOMAIN_MODULE__
  module Runtime
    class CommandBus
      attr_reader :middleware, :event_bus

      def initialize(event_bus:)
        @event_bus = event_bus
        @middleware = []
      end

      def use(name_or_middleware = nil, &block)
        if block
          @middleware << { name: name_or_middleware, handler: block }
        else
          @middleware << { name: name_or_middleware.class.name, handler: name_or_middleware }
        end
      end

      def dispatch_with_command(command, &core)
        chain = @middleware.reverse.reduce(core) do |next_handler, mw|
          handler = mw[:handler]
          -> { handler.call(command, next_handler) }
        end
        chain.call
      end
    end
  end
end
