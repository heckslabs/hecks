module Hecks
  module Projections
    module Deploy
      module Fargate
        module Containers
          # Renders one added container as a `ContainerDefinitions` entry. Extended onto
          # `Containers`.
          module DefinitionLines
            private

            def definition_yaml(container, log_group_id)
              lines = definition_head(container)
              lines.concat(port_lines(container), log_lines(container, log_group_id))
              lines.concat(env_lines(container), secret_lines(container))
              lines.join("\n")
            end

            def definition_head(container)
              lines = [
                "- Name: #{container.name}",
                "  Image: !Sub \"${#{container.repository_id}.RepositoryUri}:${#{container.tag_parameter}}\"",
                "  Essential: #{container.essential}"
              ]
              lines << "  Cpu: #{container.cpu}" if container.cpu
              lines << "  Memory: #{container.memory}" if container.memory
              lines
            end

            def port_lines(container)
              container.port ? ["  PortMappings:", "    - ContainerPort: #{container.port}"] : []
            end

            def log_lines(container, log_group_id)
              [
                "  LogConfiguration:", "    LogDriver: awslogs", "    Options:",
                "      awslogs-group: !Ref #{log_group_id}", "      awslogs-region: !Ref AWS::Region",
                "      awslogs-stream-prefix: #{container.name}"
              ]
            end

            def env_lines(container)
              return [] if container.env.empty?

              ["  Environment:"] + container.env.flat_map do |name, value|
                ["    - Name: #{name}", "      Value: #{Yaml.string(value)}"]
              end
            end

            def secret_lines(container)
              return [] if container.secrets.empty?

              ["  Secrets:"] + container.secrets.flat_map do |name, value|
                ["    - Name: #{name}", "      ValueFrom: #{Yaml.string(value)}"]
              end
            end
          end
        end
      end
    end
  end
end
