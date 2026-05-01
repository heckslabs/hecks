# Hecks::Runtime::AdapterWiring
#
# Wires command adapters into the runtime. An adapter is a module
# with methods matching command names (snake_case). When a command
# fires, the adapter method runs instead of the default behavior.
#
#   app.adapt("TestHelper", TestHelperAdapter)
#   app.run("Reset")  # calls TestHelperAdapter.reset(app: app)
#
module Hecks
  class Runtime
    # Hecks::Runtime::AdapterWiring
    #
    # Registers adapter modules that provide real behavior for generated commands.
    #
    module AdapterWiring
      # Register an adapter for an aggregate's commands.
      #
      # @param aggregate_name [String] the aggregate name
      # @param adapter [Module] module with methods matching command names
      # @return [void]
      def adapt(aggregate_name, adapter)
        @adapters ||= {}
        @adapters[aggregate_name.to_s] = adapter
        wire_adapter(aggregate_name.to_s, adapter)
      end

      private

      def wire_adapter(aggregate_name, adapter)
        app = self
        @command_bus.use :"#{aggregate_name}_adapter" do |command, next_handler|
          cmd_name = Hecks::Utils.const_short_name(command)
          method_name = cmd_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym

          if adapter.respond_to?(method_name)
            adapter.send(method_name, command: command, app: app)
            next_handler.call
          else
            next_handler.call
          end
        end
      end
    end
  end
end
