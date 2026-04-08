Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::GeneratorInternalsParagraph,
  base_dir: __dir__
)
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::SpecGeneratorsParagraph,
  base_dir: File.expand_path("spec_generator", __dir__)
)

module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::SpecGenerator
    #
    # Generates behavioral RSpec specs from domain IR. Produces specs that
    # describe what aggregates, commands, events, value objects, queries,
    # policies, lifecycles, specifications, and scopes *do*. Each concept
    # has its own mixin. Part of Generators::Infrastructure, consumed by
    # DomainGemGenerator::SpecWriter.
    #
    #   gen = SpecGenerator.new(domain)
    #   gen.generate_aggregate_spec(agg)
    #   gen.generate_command_spec(cmd, agg)
    #   gen.generate_event_spec(evt, agg)
    #   gen.generate_value_object_spec(vo, agg)
    #   gen.generate_query_spec(query, agg)
    #   gen.generate_policy_spec(policy, agg)
    #   gen.generate_lifecycle_spec(agg)
    #   gen.generate_specification_spec(spec, agg)
    #   gen.generate_scope_spec(scope, agg)
    #   gen.generate_view_spec(view)
    #   gen.generate_workflow_spec(workflow)
    #   gen.generate_service_spec(service)
    #   gen.generate_port_spec(port_name, port_def, agg)
    #
    class SpecGenerator < Hecks::Generator
      include SpecHelpers
      include AggregateSpec
      include ValueObjectSpec
      include CommandSpec
      include EventSpec
      include EntitySpec
      include QuerySpec
      include PolicySpec
      include LifecycleSpec
      include SpecificationSpec
      include ScopeSpec
      include ViewSpec
      include WorkflowSpec
      include ServiceSpec
      include PortSpec

      # Creates a new SpecGenerator for a domain.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the parsed domain IR
      def initialize(domain)
        @domain = domain
      end

      # Generates the +spec/spec_helper.rb+ content for the domain gem.
      #
      # Includes:
      # - +require "hecks"+ and +require "<gem_name>"+
      # - +require "date"+ when any aggregate uses +Date+ or +DateTime+ attributes
      # - Standard RSpec configuration (chain clauses, partial double verification,
      #   focus filtering, random ordering)
      #
      # @return [String] the complete Ruby source for +spec/spec_helper.rb+
      def generate_spec_helper
        needs_date = @domain.aggregates.any? { |a|
          a.attributes.any? { |attr| %w[Date DateTime].include?(attr.type.to_s) }
        }
        <<~RUBY
          require "hecks"
          #{"require \"date\"\n" if needs_date}require "#{@domain.gem_name}"

          RSpec.configure do |config|
            config.expect_with :rspec do |expectations|
              expectations.include_chain_clauses_in_custom_matcher_descriptions = true
            end

            config.mock_with :rspec do |mocks|
              mocks.verify_partial_doubles = true
            end

            config.filter_run_when_matching :focus
            config.order = :random
          end
        RUBY
      end

      private

      # Returns the fully qualified domain module name used in spec expectations
      # (e.g. +"PizzasDomain"+).
      #
      # @return [String] the domain module name with "Domain" suffix
      def mod_name
        bluebook_module_name(@domain.name)
      end
    end
    end
  end
end
