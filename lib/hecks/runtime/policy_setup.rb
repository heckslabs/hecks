require "set"

module Hecks
  class Runtime
      # Hecks::Runtime::PolicySetup
      #
      # Mixin that subscribes reactive policies to their trigger events.
      # Guards against re-entrant execution, checks conditions, maps
      # attributes, and dispatches commands.
      #
      module PolicySetup
        include HecksTemplating::NamingHelpers
        private

        def setup_policies
          @policies_in_flight = Set.new

          @domain.aggregates.each do |agg|
            agg.policies.select(&:reactive?).each do |policy|
              subscribe_policy(policy, "#{agg.name}.#{policy.name}")
            end
          end

          @domain.policies.select(&:reactive?).each do |policy|
            subscribe_policy(policy, "domain.#{policy.name}")
          end
        end

        def subscribe_policy(policy, policy_key)
          @event_bus.subscribe(policy.event_name) do |event|
            execute_policy(policy, policy_key, event)
          end
        end

        def execute_policy(policy, policy_key, event)
          return if reentrant?(policy_key, policy.name)

          begin
            @policies_in_flight.add(policy_key)
            return unless condition_met?(policy, event)

            attrs = extract_event_attrs(event)
            attrs = apply_policy_mapping(policy, attrs)
            attrs = attrs.merge(policy.defaults) if policy.defaults.any?

            dispatch_policy(policy, attrs)
          rescue StandardError => e
            warn "[Hecks] Policy #{policy.name} failed: #{e.message}"
          ensure
            @policies_in_flight.delete(policy_key)
          end
        end

        def reentrant?(policy_key, name)
          if @policies_in_flight.include?(policy_key)
            warn "[Hecks] Skipping re-entrant policy #{name} (already in-flight)"
            true
          end
        end

        def condition_met?(policy, event)
          !policy.condition || policy.condition.call(event)
        end

        def extract_event_attrs(event)
          event.class.instance_method(:initialize).parameters.each_with_object({}) do |(_, name), h|
            next unless name
            h[name] = event.send(name) if event.respond_to?(name)
          end
        end

        def apply_policy_mapping(policy, attrs)
          return attrs unless policy.attribute_map.any?
          policy.attribute_map.each_with_object({}) do |(from, to), h|
            h[to.to_sym] = attrs[from.to_sym] if attrs.key?(from.to_sym)
          end
        end

        def dispatch_policy(policy, attrs)
          if policy.async && @async_handler
            @async_handler.call(policy.trigger_command, attrs)
          else
            dispatch_policy_command(policy.trigger_command, attrs)
          end
        end

        def dispatch_policy_command(command_name, event_attrs)
          target_agg = @domain.aggregate_for_command(command_name)
          return @command_bus.dispatch(command_name, **event_attrs) unless target_agg

          filtered_attrs = filter_command_attrs(target_agg, command_name, event_attrs)
          agg_class = @mod.const_get(bluebook_constant_name(target_agg.name))
          method_name = resolve_command_method(command_name, target_agg.name)

          if agg_class.respond_to?(method_name)
            agg_class.send(method_name, **filtered_attrs)
          else
            @command_bus.dispatch(command_name, **filtered_attrs)
          end
        end

        def filter_command_attrs(agg, command_name, attrs)
          cmd = agg.commands.find { |c| c.name == command_name.to_s }
          return attrs unless cmd
          accepted = cmd.attributes.map { |a| a.name.to_sym }
          attrs.select { |k, _| accepted.include?(k) }
        end

        def resolve_command_method(command_name, agg_name)
          full = bluebook_snake_name(command_name)
          snake = bluebook_snake_name(agg_name)
          snake.split("_").each_index do |i|
            suffix = snake.split("_").drop(i).join("_")
            stripped = full.sub(/_#{suffix}$/, "")
            return stripped.to_sym if stripped != full
          end
          full.to_sym
        end
      end
  end
end
