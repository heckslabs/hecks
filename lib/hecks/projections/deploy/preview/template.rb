require "json"
require_relative "../text_template"
require_relative "yaml_text"
require_relative "access_yaml"
require_relative "task_yaml"
require_relative "routing_yaml"

module Hecks
  module Projections
    module Deploy
      module Preview
        # Renders `preview.yaml`, one per-branch preview stack's CloudFormation template.
        # Kept separate from the main one, so a preview can never enter a change set against it.
        module Template
          CACHING_DISABLED = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad".freeze
          ALL_VIEWER = "216adef6-5c7f-47e4-b989-5492eafa07d3".freeze

          extend YamlText

          module_function

          def render(settings)
            [
              header(settings), parameters(settings),
              "Resources:\n#{indent(resources(settings).join("\n\n"), 2)}",
              outputs
            ].join("\n") << "\n"
          end

          def header(settings)
            TextTemplate.render("preview/header.tmpl", owner_stack: settings.owner_stack,
                                                       infra_name:  settings.infra_name).chomp
          end

          def parameters(settings)
            image_tags = settings.containers.map do |c|
              <<~YAML.chomp
                #{c.logical}ImageTag:
                  Type: String
                  Default: bootstrap
              YAML
            end
            "Parameters:\n#{indent([base_parameters, *image_tags, desired_count_parameter].join("\n"), 2)}"
          end

          def base_parameters
            TextTemplate.render("preview/base_parameters.tmpl").chomp
          end

          def desired_count_parameter
            TextTemplate.render("preview/desired_count.tmpl").chomp
          end

          def resources(settings)
            [
              AccessYaml.secrets(settings), RoutingYaml.networking(settings), repositories(settings),
              cluster_and_logs(settings),
              AccessYaml.roles(settings), TaskYaml.db_init_task(settings), TaskYaml.task_definition(settings),
              RoutingYaml.load_balancing(settings),
              RoutingYaml.service(settings), distribution
            ].flatten
          end

          def repositories(settings)
            settings.containers.map do |c|
              <<~YAML.chomp
                #{c.logical}Repository:
                  Type: AWS::ECR::Repository
                  Properties:
                    RepositoryName: !Sub "#{settings.prefix}-${EnvName}-#{c.name}"
                    EmptyOnDelete: true
              YAML
            end
          end

          def cluster_and_logs(settings)
            [
              TextTemplate.render("preview/cluster.tmpl", prefix: settings.prefix).chomp,
              TextTemplate.render("preview/log_group.tmpl", prefix:         settings.prefix,
                                                            retention_days: settings.log_retention_days).chomp
            ]
          end

          def distribution
            TextTemplate.render("preview/distribution.tmpl", caching_disabled: CACHING_DISABLED,
                                                             all_viewer:       ALL_VIEWER).chomp
          end

          def outputs
            TextTemplate.render("preview/outputs.tmpl").chomp
          end
        end
      end
    end
  end
end
