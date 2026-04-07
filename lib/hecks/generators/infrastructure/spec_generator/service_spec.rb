# Hecks::Generators::Infrastructure::SpecGenerator::ServiceSpec
#
# Generates RSpec specs for domain services. Calls the service
# method with sample data and verifies it dispatches commands and
# returns results. Mixed into SpecGenerator.
#
#   gen.generate_service_spec(service)
#
module Hecks
  module Generators
    module Infrastructure
      class SpecGenerator < Hecks::Generator
        module ServiceSpec
          include HecksTemplating::NamingHelpers
          # Generates an RSpec spec for a domain service.
          #
          # @param service [Hecks::DomainModel::Behavior::Service]
          # @return [String] the complete RSpec file content
          def generate_service_spec(service)
            mod = mod_name
            method_name = domain_snake_name(service.name)
            lines = []
            lines << "require \"spec_helper\""
            lines << ""
            lines << "RSpec.describe \"#{service.name} service\" do"
            lines << "  before { @app = Hecks.load(domain, force: true) }"
            lines << ""
            lines << "  it \"is callable\" do"
            lines << "    expect(#{mod}).to respond_to(:#{method_name})"
            lines << "  end"
            lines << ""

            if service.attributes.any?
              lines << "  it \"executes and returns results\" do"
              lines << "    results = #{mod}.#{method_name}(#{example_args(service)})"
              lines << "    expect(results).to be_an(Array)"
              lines << "  end"
              lines << ""
              lines << "  it \"produces events in the event log\" do"
              lines << "    #{mod}.#{method_name}(#{example_args(service)})"
              lines << "    expect(@app.events).not_to be_empty"
              lines << "  end"
            end

            lines << "end"
            lines.join("\n") + "\n"
          end
        end
      end
    end
  end
end
