# Hecks::Generators::Infrastructure::SpecGenerator::PortSpec
#
# Generates RSpec specs for aggregate port definitions. Tests that
# allowed methods work and denied methods raise GateAccessDenied.
# Mixed into SpecGenerator.
#
#   gen.generate_port_spec(port_name, port_def, aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module PortSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a port on an aggregate.
          #
          # @param port_name [Symbol] the port name (e.g., :admin, :guest)
          # @param port_def [Hecks::DomainModel::Structure::GateDefinition]
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate]
          # @return [String] the complete RSpec file content
          def generate_port_spec(port_name, port_def, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            create_cmd = find_port_create_cmd(aggregate)

            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{safe_agg} :#{port_name} port\" do"
            lines << "  before { @app = Hecks.load(domain, gate: :#{port_name}, force: true) }"
            lines << ""

            # Test allowed methods
            allowed = port_def.allowed_methods
            denied = [:find, :all, :count] - allowed

            allowed.each do |method|
              if method == :find || method == :all || method == :count
                lines << "  it \"allows .#{method}\" do"
                lines << "    expect { #{safe_agg}.#{method}#{method == :find ? '("nonexistent")' : ''} }.not_to raise_error"
                lines << "  end"
                lines << ""
              end
            end

            # Test denied methods
            denied.each do |method|
              lines << "  it \"denies .#{method}\" do"
              lines << "    expect { #{safe_agg}.#{method}#{method == :find ? '("test")' : ''} }.to raise_error(Hecks::GateAccessDenied)"
              lines << "  end"
              lines << ""
            end

            # Test denied commands
            agg_snake = domain_snake_name(aggregate.name)
            aggregate.commands.each do |cmd|
              cmd_method = derive_port_method(cmd, aggregate)
              unless allowed.include?(cmd_method.to_sym)
                lines << "  it \"denies .#{cmd_method}\" do"
                lines << "    expect { #{safe_agg}.#{cmd_method}(#{example_args(cmd)}) }.to raise_error(Hecks::GateAccessDenied)"
                lines << "  end"
                lines << ""
              end
            end

            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def find_port_create_cmd(aggregate)
            aggregate.commands.find do |cmd|
              Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, aggregate.name).nil?
            end
          end

          def derive_port_method(cmd, agg)
            Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name).to_s
          end
        end
      end
    end
  end
end
