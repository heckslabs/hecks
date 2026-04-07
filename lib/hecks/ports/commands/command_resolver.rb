# Hecks::Commands::CommandResolver
#
# Shared resolution logic for looking up command, event, and aggregate
# definitions from the domain IR, and resolving their Ruby classes from
# the domain module namespace.
#
# Extracted from CommandBus and CommandRunner to eliminate duplication.
# Both classes include this module and rely on @domain and @mod being set.
#
#   class MyDispatcher
#     include CommandResolver
#     def initialize(domain:)
#       @domain = domain
#       @mod = Object.const_get(domain_module_name(domain.name))
#     end
#   end
#
module Hecks
  module Commands
    # Hecks::Commands::CommandResolver
    #
    # Shared resolution logic for looking up command, event, and aggregate definitions from domain IR.
    #
    module CommandResolver
      private

      # Resolves a command name to its aggregate, command, and event definitions.
      #
      # Iterates through all aggregates and their commands to find a match.
      # Commands and events are paired by index (command[i] corresponds to event[i]).
      #
      # @param command_name [String, Symbol] the command name to look up
      # @return [Array<(Aggregate, Command, Event)>] the matching aggregate, command,
      #   and event definitions
      # @raise [RuntimeError] if no matching command is found, listing all available commands
      def resolve(command_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, idx|
            return [agg, cmd, agg.events[idx]] if cmd.name == command_name.to_s
          end
        end

        available = @domain.aggregates.flat_map { |a| a.commands.map(&:name) }
        raise "Unknown command: #{command_name}. Available: #{available.join(', ')}"
      end

      # Resolves the Ruby command class from the domain module namespace.
      #
      # @param agg_name [String] the aggregate name (e.g., "Pizza")
      # @param command_name [String, Symbol] the command name (e.g., "CreatePizza")
      # @return [Class] the command class (e.g., +PizzasDomain::Pizza::Commands::CreatePizza+)
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
      # Inspects the event class's +initialize+ method to determine which parameters
      # it accepts, then copies matching values from the command object.
      #
      # @param command [Object] the command instance to extract attributes from
      # @param event_class [Class] the event class whose constructor defines the target attributes
      # @return [Hash<Symbol, Object>] keyword arguments for constructing the event
      def extract_event_attrs(command, event_class)
        event_params = event_class.instance_method(:initialize).parameters.map { |_, name| name }
        attrs = {}
        event_params.each do |param|
          attrs[param] = command.send(param) if command.respond_to?(param)
        end
        attrs
      end
    end
  end
end
