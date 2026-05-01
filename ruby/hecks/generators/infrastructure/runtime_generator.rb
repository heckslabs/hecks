# Hecks::Generators::Infrastructure::RuntimeGenerator
#
# Orchestrates all runtime wiring generators. Accepts domain IR and
# returns a Hash of { filename => Ruby source } for each wiring
# module. Each sub-generator produces a module under
# Hecks::Runtime::Generated that shadows its hand-written counterpart.
#
#   gen = RuntimeGenerator.new(domain, domain_module: "PizzasDomain")
#   gen.generate.each { |file, source| puts "#{file}: #{source.lines.size} lines" }
#
module Hecks
  module Generators
    module Infrastructure
      class RuntimeGenerator < Hecks::Generator
        GENERATORS = {
          "repository_wiring.rb" => RepositoryWiringGenerator,
          "port_wiring.rb"       => PortWiringGenerator,
          "subscriber_wiring.rb" => SubscriberWiringGenerator,
          "policy_wiring.rb"     => PolicyWiringGenerator,
          "service_wiring.rb"    => ServiceWiringGenerator,
          "workflow_wiring.rb"   => WorkflowWiringGenerator,
          "saga_wiring.rb"       => SagaWiringGenerator
        }.freeze

        def initialize(domain, domain_module:)
          @domain = domain
          @domain_module = domain_module
        end

        def generate
          GENERATORS.each_with_object({}) do |(filename, klass), result|
            gen = klass.new(@domain, domain_module: @domain_module)
            result[filename] = gen.generate
          end
        end
      end
    end
  end
end
