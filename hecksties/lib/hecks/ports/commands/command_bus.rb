
module Hecks
  module Commands
    # Hecks::Commands::CommandBus
    #
    # Dispatches commands through a middleware pipeline. Each middleware
    # wraps the next, like Rack middleware for commands. The bus resolves
    # command and event classes from the domain module, builds a middleware
    # chain, and publishes the resulting event on the event bus.
    #
    # == Middleware
    #
    # Middleware can be registered as blocks or objects. Each receives the
    # command and a +next_handler+ proc. Call +next_handler.call+ to continue
    # the chain; skip it to short-circuit.
    #
    # == Usage
    #
    #   bus = CommandBus.new(domain: domain, event_bus: event_bus)
    #
    #   bus.use :logging do |command, next_handler|
    #     puts "Dispatching #{command.class.name}"
    #     result = next_handler.call
    #     puts "Done"
    #     result
    #   end
    #
    #   bus.dispatch("CreatePizza", name: "Margherita")
    #   # => #<PizzasDomain::Pizza::Events::CreatedPizza>
    #
    class CommandBus
      include HecksTemplating::NamingHelpers
      # @return [Array<Hash>] registered middleware entries, each with :name and :handler keys
      attr_reader :middleware

      # @return [Object] the event bus used to publish events after command dispatch
      attr_reader :event_bus

      # Initializes the bus with a domain definition and an event bus for publishing.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR containing
      #   aggregate, command, and event definitions
      # @param event_bus [Hecks::EventBus] the event bus for publishing domain events
      def initialize(domain:, event_bus:)
        @domain = domain
        @event_bus = event_bus
        @mod = Object.const_get(domain_module_name(domain.name))
        @middleware = []
      end

      # Registers middleware in the pipeline. Accepts either a name + block, or
      # a middleware object that responds to +#call(command, next_handler)+.
      #
      # Block form:
      #   bus.use :logging do |command, next_handler|
      #     result = next_handler.call
      #     result
      #   end
      #
      # Object form:
      #   bus.use MyMiddleware.new
      #
      # @param name_or_middleware [Symbol, String, Object] when a block is given, this is
      #   a descriptive name for the middleware; otherwise it is the middleware object itself
      # @yield [command, next_handler] the middleware logic
      # @yieldparam command [Object] the command being dispatched
      # @yieldparam next_handler [Proc] call this to continue the middleware chain
      # @yieldreturn [Object] the result to pass back up the chain
      # @return [void]
      def use(name_or_middleware = nil, &block)
        if block
          @middleware << { name: name_or_middleware, handler: block }
        else
          @middleware << { name: name_or_middleware.class.name, handler: name_or_middleware }
        end
      end

      # Runs the middleware pipeline around a pre-built command instance,
      # using the provided block as the core (innermost) handler.
      #
      # This is used by the Hecks::Command mixin when executing commands
      # that have already been instantiated and validated. The block
      # typically contains the repository save + event publish logic.
      #
      # @param command [Object] the already-instantiated command object
      # @yield the core handler that performs the actual command logic
      # @yieldreturn [Object] the result of the command execution
      # @return [Object] the result from the middleware chain
      def dispatch_with_command(command, &core)
        chain = @middleware.reverse.reduce(core) do |next_handler, mw|
          handler = mw[:handler]
          -> { handler.call(command, next_handler) }
        end
        chain.call
      end

      # Dispatches a command by name through the middleware stack.
      #
      # Resolves the command, event, and aggregate definitions from the domain IR,
      # instantiates the command, wraps the event-creation logic in middleware,
      # and publishes the resulting event on the event bus.
      #
      # @param command_name [String, Symbol] the command name (e.g., "CreatePizza")
      # @param attrs [Hash] keyword arguments to pass to the command constructor
      # @return [Object] the domain event created and published by this command
      # @raise [RuntimeError] if the command name cannot be resolved
      def dispatch(command_name, **attrs)
        agg_def, cmd_def, event_def = resolve(command_name)

        cmd_class = resolve_class(agg_def.name, command_name)
        command = cmd_class.new(**attrs)

        # Build the innermost handler — creates and publishes the event
        event_bus = @event_bus
        inner = -> {
          event_class = resolve_event_class(agg_def.name, event_def.name)
          event_attrs = extract_event_attrs(command, event_class)
          event = event_class.new(**event_attrs)
          event_bus.publish(event)
          event
        }

        # Wrap middleware around the inner handler, outermost first
        chain = @middleware.reverse.reduce(inner) do |next_handler, mw|
          handler = mw[:handler]
          -> { handler.call(command, next_handler) }
        end

        chain.call
      end

      # Resolves a command name to its Ruby class. Used by dry_run.
      #
      # @param command_name [String] the command name (e.g., "CreatePizza")
      # @return [Class] the command class
      def resolve_command_class(command_name)
        agg_def, _, _ = resolve(command_name)
        resolve_class(agg_def.name, command_name)
      end

      private

      # Resolves a command name to its aggregate, command, and event definitions.
      #
      # @param command_name [String, Symbol] the command name to look up
      # @return [Array<(Aggregate, Command, Event)>] a three-element array of
      #   the aggregate definition, command definition, and corresponding event definition
      # @raise [RuntimeError] if no matching command is found, listing available commands
      def resolve(command_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return [agg, cmd, agg.events[i]] if cmd.name == command_name.to_s
          end
        end

        available = @domain.aggregates.flat_map { |a| a.commands.map(&:name) }
        raise "Unknown command: #{command_name}. Available: #{available.join(', ')}"
      end

      # @param agg_name [String] the aggregate name (e.g., "Pizza")
      # @param command_name [String, Symbol] the command name (e.g., "CreatePizza")
      # @return [Class] the command class
      def resolve_class(agg_name, command_name)
        agg_mod = @mod.const_get(agg_name)
        agg_mod::Commands.const_get(command_name)
      end

      # Resolves the Ruby event class from the domain module namespace.
      #
      # @param agg_name [String] the aggregate name (e.g., "Pizza")
      # @param event_name [String] the event name (e.g., "CreatedPizza")
      # @return [Class] the event class (e.g., +PizzasDomain::Pizza::Events::CreatedPizza+)
      def resolve_event_class(agg_name, event_name)
        agg_mod = @mod.const_get(agg_name)
        agg_mod::Events.const_get(event_name)
      end

      # Extracts attributes from a command that match the event's constructor parameters.
      #
      # Inspects the event class's +initialize+ method parameters and copies
      # matching values from the command object.
      #
      # @param command [Object] the command instance to extract attributes from
      # @param event_class [Class] the event class whose constructor parameters define
      #   which attributes to extract
      # @return [Hash<Symbol, Object>] keyword arguments for the event constructor
      def extract_event_attrs(command, event_class)
        event_params = event_class.instance_method(:initialize).parameters.map { |_, n| n }
        attrs = {}
        event_params.each do |param|
          attrs[param] = command.send(param) if command.respond_to?(param)
        end
        attrs
      end
      end
  end
end
