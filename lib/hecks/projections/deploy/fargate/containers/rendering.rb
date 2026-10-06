module Hecks
  module Projections
    module Deploy
      module Fargate
        module Containers
          # Renders the resources of the added containers: repositories, parameters, target groups,
          # listener rules and the service's load-balancer entries. Extended onto `Containers`.
          module Rendering
            # Renders the ECR repository of every added container.
            def repositories_yaml(layout)
              layout.extras.map do |container|
                <<~REPOSITORY.rstrip
                  #{container.repository_id}:
                    Type: AWS::ECR::Repository
                    Properties:
                      RepositoryName: #{container.repository_name}
                      ImageScanningConfiguration:
                        ScanOnPush: true
                REPOSITORY
              end.join("\n\n")
            end

            # Renders the image-tag parameter of every added container.
            def parameters_yaml(layout)
              layout.extras.map do |container|
                <<~PARAMETER
                  #{container.tag_parameter}:
                    Type: String
                    Default: latest
                    Description: ECR image tag the #{container.name} container pulls.
                PARAMETER
              end.join
            end

            # Renders the added containers as `ContainerDefinitions` list entries.
            def definitions_yaml(layout, log_group_id)
              layout.extras.map { |container| definition_yaml(container, log_group_id) }.join("\n\n")
            end

            # Renders the target group of every added container.
            def target_groups_yaml(layout, vpc_ref, deregistration_delay)
              layout.extras.select(&:port).map do |container|
                target_group_yaml(container, vpc_ref, deregistration_delay)
              end.join("\n\n")
            end

            # Renders the `TargetGroupAttributes` property for a drain delay.
            def target_group_attributes_yaml(deregistration_delay)
              return "" unless deregistration_delay

              <<~ATTRIBUTES
                TargetGroupAttributes:
                  - Key: deregistration_delay.timeout_seconds
                    Value: "#{deregistration_delay}"
              ATTRIBUTES
            end

            # Renders one listener rule per route.
            def listener_rules_yaml(layout, listener_id)
              layout.routes.map do |route|
                target = layout.all.find { |container| container.name == route.container }
                listener_rule_yaml(route, target, listener_id).rstrip
              end.join("\n\n")
            end

            # Renders the service's `LoadBalancers` entries for the added containers.
            def load_balancers_yaml(layout)
              layout.extras.select(&:port).map do |container|
                <<~ENTRY
                  - ContainerName: #{container.name}
                    ContainerPort: #{container.port}
                    TargetGroupArn: !Ref #{container.target_group_id}
                ENTRY
              end.join
            end

            # Writes the `DependsOn` value that holds the service until the listener and its rules
            # exist.
            def depends_on(layout, listener_id)
              return listener_id if layout.routes.empty?

              Yaml.flow_list([listener_id, *layout.routes.map(&:id)])
            end

            # Finds the first and last container port the load balancer must reach.
            def port_range(layout)
              ports = layout.balanced.map(&:port)
              ports.min..ports.max
            end

            private

            def target_group_yaml(container, vpc_ref, deregistration_delay)
              attributes = target_group_attributes_yaml(deregistration_delay).gsub(/^/, "    ")
              "#{target_group_head(container, vpc_ref)}#{attributes}".rstrip
            end

            def target_group_head(container, vpc_ref)
              <<~HEAD
                #{container.target_group_id}:
                  Type: AWS::ElasticLoadBalancingV2::TargetGroup
                  Properties:
                    TargetType: ip
                    Port: #{container.port}
                    Protocol: HTTP
                    VpcId: #{vpc_ref}
                    HealthCheckPath: #{container.health_path}
                    HealthCheckPort: "#{container.port}"
              HEAD
            end

            def listener_rule_yaml(route, target, listener_id)
              <<~RULE
                #{route.id}:
                  Type: AWS::ElasticLoadBalancingV2::ListenerRule
                  Properties:
                    ListenerArn: !Ref #{listener_id}
                    Priority: #{route.priority}
                    Conditions:
                      - Field: path-pattern
                        Values: #{Yaml.flow_list(route.paths)}
                    Actions:
                      - Type: forward
                        TargetGroupArn: !Ref #{target.target_group_id}
              RULE
            end
          end
        end
      end
    end
  end
end
