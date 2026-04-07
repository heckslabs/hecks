# Hecks::Generators::Infrastructure::SpecGenerator::SpecificationSpec
#
# Generates RSpec specs for domain specifications: verifies the
# specification class exists and satisfied_by? is callable with
# concrete pass/fail examples. Mixed into SpecGenerator.
#
#   gen.generate_specification_spec(specification, aggregate)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module SpecificationSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a specification on an aggregate.
          #
          # @param specification [Hecks::DomainModel::Behavior::Specification]
          # @param aggregate [Hecks::DomainModel::Structure::Aggregate]
          # @return [String] the complete RSpec file content
          def generate_specification_spec(specification, aggregate)
            safe_agg = domain_constant_name(aggregate.name)
            spec_fqn = full_class_name("#{safe_agg}::Specifications::#{specification.name}")

            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe #{spec_fqn} do"
            lines << "  it \"responds to satisfied_by?\" do"
            lines << "    expect(described_class).to respond_to(:satisfied_by?)"
            lines << "  end"
            lines << ""
            lines << "  it \"returns a boolean for a sample object\" do"
            lines << "    obj = OpenStruct.new(#{sample_attrs_for_spec(aggregate)})"
            lines << "    result = described_class.satisfied_by?(obj)"
            lines << "    expect([true, false]).to include(result)"
            lines << "  end"
            lines << "end"
            lines.join("\n") + "\n"
          end

          private

          def sample_attrs_for_spec(aggregate)
            aggregate.attributes.map { |a|
              "#{a.name}: #{example_value(a)}"
            }.join(", ")
          end
        end
      end
    end
  end
end
