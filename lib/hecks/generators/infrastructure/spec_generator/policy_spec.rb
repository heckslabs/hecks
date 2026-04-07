# Hecks::Generators::Infrastructure::SpecGenerator::PolicySpec
#
# Generates RSpec specs for reactive policies: executes the command
# that emits the trigger event, then verifies the full reactive chain
# appears in the event log. Mixed into SpecGenerator.
#
#   gen.generate_policy_spec(policy, aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module PolicySpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a reactive policy.
          #
          # The generated spec:
          # 1. Boots the domain with memory adapters
          # 2. Creates prerequisite aggregates
          # 3. Executes the command that emits the trigger event
          # 4. Verifies both the trigger event and the chained event
          #    appear in app.events
          #
          # @param policy [Hecks::DomainModel::Behavior::Policy] the policy IR
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the owning aggregate
          # @return [String, nil] the RSpec file content, or nil if not reactive
          def generate_policy_spec(policy, aggregate)
            return nil unless policy.reactive?

            safe_agg = domain_constant_name(aggregate.name)
            trigger_cmd = find_command_for_event(policy.event_name)
            return nil unless trigger_cmd

            trigger_agg = find_aggregate_for_command(trigger_cmd)
            return nil unless trigger_agg

            triggered_event = infer_event_name(policy.trigger_command)
            trigger_cmd_method = derive_method(trigger_cmd, trigger_agg)
            trigger_safe = domain_constant_name(trigger_agg.name)
            is_update = is_update_cmd?(trigger_cmd, trigger_agg)

            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{policy.name} policy\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""
            lines << "  it \"#{policy.event_name} triggers #{policy.trigger_command} → emits #{triggered_event}\" do"

            if is_update
              create_cmd = find_create_cmd(trigger_agg)
              if create_cmd
                create_method = derive_method(create_cmd, trigger_agg)
                lines << "    agg = #{trigger_safe}.#{create_method}(#{example_args(create_cmd)})"
                lines << "    #{trigger_safe}.#{trigger_cmd_method}(#{update_args_for(trigger_cmd, trigger_agg)})"
              end
            else
              lines << "    #{trigger_safe}.#{trigger_cmd_method}(#{example_args(trigger_cmd)})"
            end

            lines << "    event_names = @app.events.map { |e| e.class.name.split(\"::\").last }"
            lines << "    expect(event_names).to include(\"#{policy.event_name}\")"
            lines << "    expect(event_names).to include(\"#{triggered_event}\")"
            lines << "  end"
            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def find_command_for_event(event_name)
            @domain.aggregates.each do |agg|
              agg.commands.each_with_index do |cmd, i|
                return cmd if agg.events[i]&.name == event_name
              end
            end
            nil
          end

          def find_aggregate_for_command(cmd)
            @domain.aggregates.find { |agg| agg.commands.include?(cmd) }
          end

          def infer_event_name(command_name)
            @domain.aggregates.each do |agg|
              agg.commands.each_with_index do |cmd, i|
                return agg.events[i].name if cmd.name == command_name && agg.events[i]
              end
            end
            # Fallback: use the command's own inference
            cmd_obj = @domain.aggregates.flat_map(&:commands).find { |c| c.name == command_name }
            cmd_obj&.inferred_event_name || "#{command_name}ed"
          end

          def derive_method(cmd, agg)
            Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name).to_s
          end

          def is_update_cmd?(cmd, agg)
            Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, agg.name) != nil
          end

          def find_create_cmd(agg)
            agg.commands.find { |c| !is_update_cmd?(c, agg) }
          end

          def update_args_for(cmd, agg)
            self_ref = Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, agg.name)

            cmd.attributes.map { |attr|
              if self_ref && attr.name == self_ref.name
                "#{attr.name}: agg.id"
              else
                "#{attr.name}: #{example_value(attr)}"
              end
            }.join(", ")
          end
        end
      end
    end
  end
end
