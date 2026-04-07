# Hecks::Generators::Infrastructure::PolicyWiringGenerator
#
# Generates a module that subscribes reactive policies to their
# trigger events. Replaces the hand-written PolicySetup mixin which
# iterates domain IR at boot time. Helper methods for re-entrancy
# guards, condition checks, and command dispatch are included in
# the generated module.
#
#   gen = PolicyWiringGenerator.new(domain, domain_module: "PizzasDomain")
#   gen.generate  # => Ruby source string
#
module Hecks
  module Generators
    module Infrastructure
      class PolicyWiringGenerator < Hecks::Generator
        def initialize(domain, domain_module:)
          @domain = domain
          @domain_module = domain_module
        end

        def generate
          lines = []
          lines << "module Hecks"
          lines << "  class Runtime"
          lines << "    module Generated"
          lines << "      module PolicyWiring"
          lines << "        include HecksTemplating::NamingHelpers"
          lines << "        private"
          lines << ""
          lines << "        def setup_policies"
          lines << "          @policies_in_flight = Set.new"

          aggregate_policies.each do |agg_name, policies|
            lines << ""
            lines << "          # #{agg_name} policies"
            policies.each do |policy|
              key = "#{agg_name}.#{policy.name}"
              lines << "          subscribe_policy_event(#{policy.event_name.inspect}, #{key.inspect})"
            end
          end

          domain_policies.each do |policy|
            key = "domain.#{policy.name}"
            lines << "          subscribe_policy_event(#{policy.event_name.inspect}, #{key.inspect})"
          end

          lines << "        end"
          lines << ""
          lines.concat(helper_lines)
          lines << "      end"
          lines << "    end"
          lines << "  end"
          lines << "end"
          lines.join("\n") + "\n"
        end

        private

        def aggregate_policies
          pairs = []
          @domain.aggregates.each do |agg|
            reactive = agg.policies.select(&:reactive?)
            pairs << [agg.name, reactive] if reactive.any?
          end
          pairs
        end

        def domain_policies
          @domain.respond_to?(:policies) ? @domain.policies.select(&:reactive?) : []
        end

        def helper_lines
          lines = []
          lines << "        def subscribe_policy_event(event_name, policy_key)"
          lines << "          policy = find_policy(policy_key)"
          lines << "          @event_bus.subscribe(event_name) do |event|"
          lines << "            execute_policy(policy, policy_key, event)"
          lines << "          end"
          lines << "        end"
          lines << ""
          lines << "        def find_policy(key)"
          lines << '          agg_name, pol_name = key.split(".", 2)'
          lines << '          if agg_name == "domain"'
          lines << "            @domain.policies.find { |p| p.name == pol_name }"
          lines << "          else"
          lines << "            agg = @domain.aggregates.find { |a| a.name == agg_name }"
          lines << "            agg&.policies&.find { |p| p.name == pol_name }"
          lines << "          end"
          lines << "        end"
          lines << ""
          lines << "        def execute_policy(policy, policy_key, event)"
          lines << "          return if @policies_in_flight.include?(policy_key)"
          lines << "          begin"
          lines << "            @policies_in_flight.add(policy_key)"
          lines << "            return unless !policy.condition || policy.condition.call(event)"
          lines << "            attrs = event.class.instance_method(:initialize).parameters.each_with_object({}) do |(_, name), h|"
          lines << "              next unless name"
          lines << "              h[name] = event.send(name) if event.respond_to?(name)"
          lines << "            end"
          lines << "            attrs = policy.attribute_map.any? ? policy.attribute_map.each_with_object({}) { |(from, to), h| h[to.to_sym] = attrs[from.to_sym] if attrs.key?(from.to_sym) } : attrs"
          lines << '            attrs = attrs.merge(policy.defaults) if policy.defaults.any?'
          lines << "            if policy.async && @async_handler"
          lines << "              @async_handler.call(policy.trigger_command, attrs)"
          lines << "            else"
          lines << "              target_agg = @domain.aggregate_for_command(policy.trigger_command)"
          lines << "              if target_agg"
          lines << '                cmd = target_agg.commands.find { |c| c.name == policy.trigger_command.to_s }'
          lines << "                filtered = cmd ? attrs.select { |k, _| cmd.attributes.map { |a| a.name.to_sym }.include?(k) } : attrs"
          lines << "                agg_class = @mod.const_get(domain_constant_name(target_agg.name))"
          lines << "                method_name = resolve_command_method(policy.trigger_command, target_agg.name)"
          lines << "                if agg_class.respond_to?(method_name)"
          lines << "                  agg_class.send(method_name, **filtered)"
          lines << "                else"
          lines << "                  @command_bus.dispatch(policy.trigger_command, **filtered)"
          lines << "                end"
          lines << "              else"
          lines << "                @command_bus.dispatch(policy.trigger_command, **attrs)"
          lines << "              end"
          lines << "            end"
          lines << '          rescue StandardError => e'
          lines << '            warn "[Hecks] Policy #{policy.name} failed: #{e.message}"'
          lines << "          ensure"
          lines << "            @policies_in_flight.delete(policy_key)"
          lines << "          end"
          lines << "        end"
          lines << ""
          lines << "        def resolve_command_method(command_name, agg_name)"
          lines << "          full = domain_snake_name(command_name)"
          lines << "          snake = domain_snake_name(agg_name)"
          lines << '          snake.split("_").each_index do |i|'
          lines << '            suffix = snake.split("_").drop(i).join("_")'
          lines << '            stripped = full.sub(/_#{suffix}$/, "")'
          lines << "            return stripped.to_sym if stripped != full"
          lines << "          end"
          lines << "          full.to_sym"
          lines << "        end"
          lines
        end
      end
    end
  end
end
