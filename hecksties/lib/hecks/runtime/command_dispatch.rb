# Hecks::Runtime::CommandDispatch
#
# Command execution and event subscription on the runtime. Provides
# the public API for running commands, subscribing to events, and
# querying runtime state.
#
#   app.run("CreatePizza", name: "Margherita")
#   app.on("CreatedPizza") { |e| puts e.name }
#   app["Pizza"].all
#
module Hecks
  class Runtime
    module CommandDispatch
      # Retrieve the repository for a named aggregate.
      #
      # @param name [String, Symbol] the aggregate name
      # @return [Object] the repository
      def [](name)
        @repositories[name.to_s]
      end

      # Execute a command through the command bus.
      #
      # @param command_name [String, Symbol] the command name
      # @param attrs [Hash] the command attributes
      # @return [Object] the command result
      def run(command_name, **attrs)
        @command_bus.dispatch(command_name, **attrs)
      end

      # Preview what a command would do without persisting.
      #
      # @param command_name [String] the command name
      # @param attrs [Hash] the command attributes
      # @return [Hecks::DryRunResult]
      def dry_run(command_name, **attrs)
        cmd_class = @command_bus.resolve_command_class(command_name)
        cmd = cmd_class.dry_call(**attrs)
        chain = trace_reactive_chain(command_name)
        DryRunResult.new(command: cmd, aggregate: cmd.aggregate, event: cmd.event, reactive_chain: chain)
      end

      # Register an async handler for policies marked async: true.
      #
      # @yield [event] block that handles async event processing
      # @return [void]
      def async(&handler)
        @async_handler = handler
      end

      # Subscribe to a named event on the event bus.
      #
      # @param event_name [String, Symbol] the event name
      # @yield [event] block called on publish
      # @return [void]
      def on(event_name, &handler)
        @event_bus.subscribe(event_name, &handler)
      end

      # Returns all events published since boot.
      #
      # @return [Array<Hash>]
      def events
        @event_bus.events
      end

      private

      def trace_reactive_chain(command_name)
        return [] unless defined?(Hecks::FlowGenerator)
        flows = Hecks::FlowGenerator.new(@domain).trace_flows
        flow = flows.find { |f| f[:steps]&.first&.dig(:command) == command_name.to_s }
        return [] unless flow
        flow[:steps].drop(1)
      end
    end
  end
end
