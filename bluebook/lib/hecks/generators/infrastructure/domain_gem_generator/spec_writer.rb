module Hecks
  module Generators
    module Infrastructure
      class DomainGemGenerator < Hecks::Generator
        # Hecks::Generators::Infrastructure::DomainGemGenerator::SpecWriter
        #
        # Mixin that writes RSpec specs for all domain concepts in the gem.
        # Delegates to SpecGenerator for spec content. Part of
        # DomainGemGenerator, invoked during DomainGemGenerator#generate.
        #
        #   # Mixed into DomainGemGenerator:
        #   generate_specs(root, gem_name, mod)
        #
        module SpecWriter
          include HecksTemplating::NamingHelpers
          private

          # Writes all RSpec spec files for the domain gem.
          #
          # Creates specs for: aggregates, value objects, entities, commands,
          # events, queries, policies, lifecycles, specifications, and scopes.
          #
          # @param root [String] absolute path to the gem root directory
          # @param gem_name [String] snake_case gem name
          # @param mod [String] PascalCase domain module name
          # @return [void]
          def generate_specs(root, gem_name, mod)
            sg = SpecGenerator.new(@domain)
            write_file(root, "spec/spec_helper.rb", sg.generate_spec_helper)
            write_file(root, ".rspec", "--format documentation\n--color\n--require spec_helper\n")
            @domain.aggregates.each do |agg|
              snake = bluebook_snake_name(bluebook_constant_name(agg.name))
              write_file(root, "spec/#{snake}/#{snake}_spec.rb", sg.generate_aggregate_spec(agg))

              agg.value_objects.each do |vo|
                write_file(root, "spec/#{snake}/#{bluebook_snake_name(vo.name)}_spec.rb", sg.generate_value_object_spec(vo, agg))
              end

              agg.entities.each do |ent|
                write_file(root, "spec/#{snake}/#{bluebook_snake_name(ent.name)}_spec.rb", sg.generate_entity_spec(ent, agg))
              end

              agg.commands.each do |cmd|
                write_file(root, "spec/#{snake}/commands/#{bluebook_snake_name(cmd.name)}_spec.rb", sg.generate_command_spec(cmd, agg))
              end

              agg.events.each do |evt|
                write_file(root, "spec/#{snake}/events/#{bluebook_snake_name(evt.name)}_spec.rb", sg.generate_event_spec(evt, agg))
              end

              agg.queries.each do |query|
                content = sg.generate_query_spec(query, agg)
                next unless content
                write_file(root, "spec/#{snake}/queries/#{bluebook_snake_name(query.name)}_spec.rb", content)
              end

              agg.policies.each do |policy|
                content = sg.generate_policy_spec(policy, agg)
                next unless content
                write_file(root, "spec/#{snake}/policies/#{bluebook_snake_name(policy.name)}_spec.rb", content)
              end

              if agg.lifecycle
                content = sg.generate_lifecycle_spec(agg)
                write_file(root, "spec/#{snake}/lifecycle_spec.rb", content) if content
              end

              agg.specifications.each do |spec|
                content = sg.generate_specification_spec(spec, agg)
                next unless content
                write_file(root, "spec/#{snake}/specifications/#{bluebook_snake_name(spec.name)}_spec.rb", content)
              end

              agg.scopes.each do |scope|
                content = sg.generate_scope_spec(scope, agg)
                next unless content
                write_file(root, "spec/#{snake}/scopes/#{scope.name}_spec.rb", content)
              end

              agg.ports.each do |port_name, port_def|
                content = sg.generate_port_spec(port_name, port_def, agg)
                next unless content
                write_file(root, "spec/#{snake}/ports/#{port_name}_spec.rb", content)
              end
            end

            # Domain-level specs
            @domain.views.each do |view|
              content = sg.generate_view_spec(view)
              next unless content
              write_file(root, "spec/views/#{bluebook_snake_name(view.name)}_spec.rb", content)
            end

            @domain.workflows.each do |wf|
              content = sg.generate_workflow_spec(wf)
              next unless content
              write_file(root, "spec/workflows/#{bluebook_snake_name(wf.name)}_spec.rb", content)
            end

            @domain.services.each do |svc|
              content = sg.generate_service_spec(svc)
              next unless content
              write_file(root, "spec/services/#{bluebook_snake_name(svc.name)}_spec.rb", content)
            end
          end
        end
      end
    end
  end
end
