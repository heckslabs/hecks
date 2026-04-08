module Hecks
  class Workshop
    class Playground
      # Hecks::Workshop::Playground::RuntimeResolver
      #
      # Resolves generated command and event classes at runtime by walking the
      # domain model's aggregates and looking up the corresponding constants
      # in the compiled gem module.
      #
      # Mixed into Playground to separate class resolution from execution logic.
      # All methods are private since they are internal helpers used by Playground's
      # execute method and initialization.
      #
      #   class Playground
      #     include RuntimeResolver
      #     # provides: resolve_command, resolve_event_for, resolve_domain_command,
      #     #           available_commands, collect_policies, check_policies
      #   end
      #
      module RuntimeResolver
        include HecksTemplating::NamingHelpers
        private

        # Resolve a command class constant from the compiled domain module.
        #
        # Walks the domain IR to find which aggregate owns the command, then
        # looks up the class under that aggregate's Commands namespace. This
        # avoids polluting other aggregates' namespaces via const_missing.
        #
        # @param command_name [String] the command class name (e.g. "CreatePizza")
        # @return [Class] the resolved command class
        # @raise [RuntimeError] if no aggregate owns a command with that name
        def resolve_command(command_name)
          mod = Object.const_get(@mod_name)

          # Find the aggregate that owns this command via domain IR first,
          # then load only from that aggregate's Commands module. This avoids
          # polluting other aggregates' namespaces via const_missing.
          @domain.aggregates.each do |agg|
            next unless agg.commands.any? { |c| c.name == command_name.to_s }
            agg_class = mod.const_get(domain_constant_name(agg.name))
            return agg_class::Commands.const_get(command_name)
          end

          raise "Unknown command: #{command_name}. Available: #{available_commands.join(', ')}"
        end

        # Resolve the event class that corresponds to a given command.
        #
        # Commands and events are paired by index within an aggregate (the
        # first command maps to the first event, etc.). Looks up the event
        # class in the aggregate's Events namespace.
        #
        # @param command_name [String] the command class name (e.g. "CreatePizza")
        # @return [Class] the resolved event class (e.g. PizzasDomain::Pizza::Events::CreatedPizza)
        # @raise [RuntimeError] if no event is mapped for the given command
        def resolve_event_for(command_name)
          mod = Object.const_get(@mod_name)

          @domain.aggregates.each do |agg|
            agg.commands.each_with_index do |cmd, i|
              if cmd.name == command_name.to_s
                event = agg.events[i]
                agg_class = mod.const_get(domain_constant_name(agg.name))
                return agg_class::Events.const_get(event.name)
              end
            end
          end

          raise "No event mapped for command: #{command_name}"
        end

        # Find the domain IR command definition by name.
        #
        # Searches all aggregates for a command with the given name and returns
        # the BluebookModel::Structure::Command struct (not the generated class).
        #
        # @param command_name [String] the command name to find
        # @return [BluebookModel::Structure::Command, nil] the command definition, or nil if not found
        def resolve_domain_command(command_name)
          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              return cmd if cmd.name == command_name.to_s
            end
          end
          nil
        end

        # List all command names across all aggregates.
        #
        # @return [Array<String>] command names from the domain IR
        def available_commands
          @domain.aggregates.flat_map { |a| a.commands.map(&:name) }
        end

        # Collect all policy definitions from all aggregates.
        #
        # @return [Array<BluebookModel::Structure::Policy>] all policies in the domain
        def collect_policies
          @domain.aggregates.flat_map(&:policies)
        end

        # Find policies that should fire in response to a given event.
        #
        # Matches policies whose +event_name+ equals the short class name
        # of the provided event object.
        #
        # @param event [Object] an event instance with a class name like "PizzasDomain::Pizza::Events::CreatedPizza"
        # @return [Array<BluebookModel::Structure::Policy>] policies triggered by this event
        def check_policies(event)
          event_name = Hecks::Utils.const_short_name(event)
          @policies.select { |p| p.event_name == event_name }
        end
      end
    end
  end
end
