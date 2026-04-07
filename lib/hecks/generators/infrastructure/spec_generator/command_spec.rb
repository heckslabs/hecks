module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::SpecGenerator::CommandSpec
        #
        # Generates RSpec specs for commands: attribute assignment, event
        # emission declarations, runtime execution with persistence, and
        # event log validation. Mixed into SpecGenerator.
        #
        module CommandSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec file for a command class.
          #
          # The generated spec covers:
          # - Attribute assignment: verifies each attribute is accessible
          # - Event emission: verifies +described_class.event_name+
          # - Runtime execution: calls the command, verifies persistence
          # - Event log: verifies the expected event appears in app.events
          #
          # @param command [Hecks::DomainModel::Behavior::Command] the command IR
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate] the owning
          #   aggregate, used to build the fully qualified class name
          # @return [String] the complete RSpec file content
          def generate_command_spec(command, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            fqn = full_class_name("#{safe_agg}::Commands::#{command.name}")
            event_name = command.inferred_event_name
            cmd_method = derive_command_method(command, aggregate)
            is_update = update_command?(command, aggregate)
            lines = []

            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe #{fqn} do"
            lines.concat(attribute_block(command))
            lines.concat(event_declaration_block(event_name))
            lines.concat(execution_block(command, aggregate, safe_agg, cmd_method, event_name, is_update))
            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def attribute_block(command)
            lines = []
            lines << "  describe \"attributes\" do"
            lines << "    subject(:command) { described_class.new(#{example_args(command)}) }"
            lines << ""
            command.attributes.each do |attr|
              lines << "    it \"has #{attr.name}\" do"
              lines << "      expect(command.#{attr.name}).to eq(#{example_value(attr)})"
              lines << "    end"
              lines << ""
            end
            lines << "  end"
            lines << ""
            lines
          end

          def event_declaration_block(event_name)
            lines = []
            lines << "  describe \"event\" do"
            lines << "    it \"emits #{event_name}\" do"
            lines << "      expect(described_class.event_name).to eq(\"#{event_name}\")"
            lines << "    end"
            lines << "  end"
            lines << ""
            lines
          end

          def execution_block(command, aggregate, safe_agg, cmd_method, event_name, is_update)
            lines = []
            lines << "  describe \"execution\" do"
            lines << "    before { @app = Hecks.load(domain, force: true) }"
            lines << ""

            if is_update
              lines.concat(update_execution_lines(command, aggregate, safe_agg, cmd_method, event_name))
            else
              lines.concat(create_execution_lines(command, safe_agg, cmd_method, event_name))
            end

            lines << "  end"
            lines
          end

          def create_execution_lines(command, safe_agg, cmd_method, event_name)
            lines = []
            lines << "    it \"persists the aggregate\" do"
            lines << "      result = #{safe_agg}.#{cmd_method}(#{example_args(command)})"
            lines << "      expect(result).not_to be_nil"
            lines << "      expect(#{safe_agg}.find(result.id)).not_to be_nil"
            lines << "    end"
            lines << ""
            lines << "    it \"emits #{event_name} to the event log\" do"
            lines << "      #{safe_agg}.#{cmd_method}(#{example_args(command)})"
            lines << "      event_names = @app.events.map { |e| e.class.name.split(\"::\").last }"
            lines << "      expect(event_names).to include(\"#{event_name}\")"
            lines << "    end"
            lines
          end

          def update_execution_lines(command, aggregate, safe_agg, cmd_method, event_name)
            create_cmd = find_create_cmd(aggregate)
            return [] unless create_cmd

            create_method = derive_command_method(create_cmd, aggregate)
            self_ref = find_self_ref_attr(command, aggregate)
            lines = []
            lines << "    it \"updates the aggregate and emits #{event_name}\" do"
            lines << "      agg = #{safe_agg}.#{create_method}(#{example_args(create_cmd)})"
            lines << "      #{safe_agg}.#{cmd_method}(#{update_args(command, self_ref)})"
            lines << "      event_names = @app.events.map { |e| e.class.name.split(\"::\").last }"
            lines << "      expect(event_names).to include(\"#{event_name}\")"
            lines << "    end"
            lines
          end

          def derive_command_method(cmd, aggregate)
            Hecks::Conventions::CommandContract.method_name(cmd.name, aggregate.name).to_s
          end

          def update_command?(cmd, aggregate)
            agg_snake = domain_snake_name(aggregate.name)
            (cmd.references || []).any? { |ref|
              Hecks::Utils.underscore(ref.type) == agg_snake
            }
          end

          def find_create_cmd(aggregate)
            aggregate.commands.find { |c| !update_command?(c, aggregate) }
          end

          def find_self_ref_attr(cmd, aggregate)
            agg_snake = domain_snake_name(aggregate.name)
            (cmd.references || []).find { |ref|
              Hecks::Utils.underscore(ref.type) == agg_snake
            }
          end

          def update_args(cmd, self_ref)
            parts = cmd.attributes.map do |attr|
              "#{attr.name}: #{example_value(attr)}"
            end
            (cmd.references || []).each do |ref|
              if self_ref && ref == self_ref
                parts << "#{ref.name}: agg.id"
              else
                parts << "#{ref.name}: \"ref-id-123\""
              end
            end
            parts.join(", ")
          end
        end
      end
    end
  end
end
