# Hecks::Generators::Infrastructure::SpecGenerator::WorkflowSpec
#
# Generates RSpec specs for domain workflows. Calls the workflow
# method with sample data and verifies it returns a result and
# produces events. Mixed into SpecGenerator.
#
#   gen.generate_workflow_spec(workflow)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module WorkflowSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a domain workflow.
          #
          # @param workflow [Hecks::DomainModel::Behavior::Workflow]
          # @return [String] the complete RSpec file content
          def generate_workflow_spec(workflow)
            mod = mod_name
            method_name = domain_snake_name(workflow.name)
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{workflow.name} workflow\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""

            # Build sample attrs from the first step's command
            first_cmd = find_workflow_command(workflow)
            if first_cmd
              lines << "  it \"executes and returns a result\" do"
              lines << "    result = #{mod}.#{method_name}(#{example_args(first_cmd)})"
              lines << "    expect(result).not_to be_nil"
              lines << "  end"
              lines << ""
              lines << "  it \"produces events in the event log\" do"
              lines << "    #{mod}.#{method_name}(#{example_args(first_cmd)})"
              lines << "    expect(@app.events).not_to be_empty"
              lines << "  end"
            else
              lines << "  it \"is callable\" do"
              lines << "    expect(#{mod}).to respond_to(:#{method_name})"
              lines << "  end"
            end

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def find_workflow_command(workflow)
            return nil if workflow.steps.empty?
            first_step = workflow.steps.first
            cmd_name = first_step.respond_to?(:command) ? first_step.command : (first_step[:command] || first_step["command"])
            return nil unless cmd_name

            @domain.aggregates.each do |agg|
              cmd = agg.commands.find { |c| c.name == cmd_name }
              return cmd if cmd
            end
            nil
          end
        end
      end
    end
  end
end
