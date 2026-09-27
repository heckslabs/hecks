require "json"
require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The network edge of a preview stack: security groups, target groups, the
        # load balancer, its listener rules and the service that registers the containers.
        #
        # A container is reachable when it is the default or owns a path. Paths are
        # split into rules of at most five, the most a load balancer condition holds.
        module RoutingYaml
          CLOUDFRONT_PREFIX_LIST = "pl-3b927c52".freeze
          PATHS_PER_RULE = 5
          INGRESS_NOTE = <<~NOTE.chomp.freeze
            # One ingress rule per routed container on the shared owner security group, removed
            # with the stack. The group has a rules-per-group quota, so delete stale previews.
          NOTE

          extend YamlText

          module_function

          # Renders the load balancer's security group and one ingress rule per routed container.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<String>] the resource blocks
          def networking(settings)
            ingress = settings.containers.select(&:routed?).map do |c|
              <<~YAML.chomp
                ComputeIngressFromAlb#{c.logical}:
                  Type: AWS::EC2::SecurityGroupIngress
                  Properties:
                    GroupId: !Ref OwningSecurityGroupId
                    IpProtocol: tcp
                    FromPort: #{c.port}
                    ToPort: #{c.port}
                    SourceSecurityGroupId: !Ref AlbSecurityGroup
              YAML
            end
            [alb_security_group(settings), "#{INGRESS_NOTE}\n#{ingress.join("\n\n")}"]
          end

          # Renders the load balancer's security group, open to CloudFront's prefix list only.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the resource block
          def alb_security_group(settings)
            <<~YAML.chomp
              AlbSecurityGroup:
                Type: AWS::EC2::SecurityGroup
                Properties:
                  VpcId: !Ref OwningVpcId
                  GroupDescription: !Sub "#{settings.infra_name} preview ${EnvName} ALB - HTTP ingress from CloudFront only"
                  SecurityGroupIngress:
                    # The AWS-managed com.amazonaws.global.cloudfront.origin-facing prefix list.
                    - IpProtocol: tcp
                      FromPort: 80
                      ToPort: 80
                      SourcePrefixListId: #{CLOUDFRONT_PREFIX_LIST}
            YAML
          end

          # Renders the target groups, the load balancer, its listener and the path rules.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<String>] the resource blocks
          def load_balancing(settings)
            routed = settings.containers.select(&:routed?)
            [*routed.map { |c| target_group(c) }, alb(settings), listener(settings), *listener_rules(settings)]
          end

          # Renders the target group of one routed container.
          #
          # @param container [Containers::Entry] the container
          # @return [String] the resource block
          def target_group(container)
            <<~YAML.chomp
              #{container.logical}TargetGroup:
                Type: AWS::ElasticLoadBalancingV2::TargetGroup
                Properties:
                  TargetType: ip
                  Port: #{container.port}
                  Protocol: HTTP
                  VpcId: !Ref OwningVpcId
                  HealthCheckPath: #{container.health_check_path}
                  HealthCheckPort: "#{container.port}"
            YAML
          end

          # Renders the internet-facing application load balancer.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the resource block
          def alb(settings)
            <<~YAML.chomp
              Alb:
                Type: AWS::ElasticLoadBalancingV2::LoadBalancer
                Properties:
                  Name: !Sub "#{settings.alb_prefix}-${EnvName}"
                  Scheme: internet-facing
                  Type: application
                  SecurityGroups: [!Ref AlbSecurityGroup]
                  Subnets: [!Ref OwningPublicSubnetAId, !Ref OwningPublicSubnetBId]
            YAML
          end

          # Renders the port 80 listener, whose default action goes to the default container.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the resource block
          def listener(settings)
            <<~YAML.chomp
              Listener:
                Type: AWS::ElasticLoadBalancingV2::Listener
                Properties:
                  LoadBalancerArn: !Ref Alb
                  Port: 80
                  Protocol: HTTP
                  DefaultActions:
                    - Type: forward
                      TargetGroupArn: !Ref #{settings.default_container.logical}TargetGroup
            YAML
          end

          # Lists the listener rules to render: a non-default container's paths, sliced to
          # fit one condition.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<Hash{Symbol => Object}>] entries with `:container`, `:paths` and `:id`
          def rule_specs(settings)
            settings.containers.reject(&:default).select(&:routed?).flat_map do |c|
              c.paths.each_slice(PATHS_PER_RULE).with_index.map do |slice, n|
                { container: c, paths: slice, id: rule_id(c, n) }
              end
            end
          end

          # Renders every listener rule, with priorities counting up in tens.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<String>] the resource blocks
          def listener_rules(settings)
            rule_specs(settings).each_with_index.map { |spec, i| listener_rule(spec, (i + 1) * 10) }
          end

          # Renders one listener rule.
          #
          # @param spec [Hash{Symbol => Object}] one entry of `rule_specs`
          # @param priority [Integer] the rule's listener priority
          # @return [String] the resource block
          def listener_rule(spec, priority)
            <<~YAML.chomp
              #{spec[:id]}:
                Type: AWS::ElasticLoadBalancingV2::ListenerRule
                Properties:
                  ListenerArn: !Ref Listener
                  Priority: #{priority}
                  Conditions:
                    - Field: path-pattern
                      Values: [#{spec[:paths].map { |p| JSON.generate(p) }.join(', ')}]
                  Actions:
                    - Type: forward
                      TargetGroupArn: !Ref #{spec[:container].logical}TargetGroup
            YAML
          end

          # Names one listener rule's logical id.
          #
          # @param container [Containers::Entry] the container the rule forwards to
          # @param slice [Integer] the zero-based index of the rule among that container's rules
          # @return [String] the logical id
          def rule_id(container, slice) = "ListenerRule#{container.logical}#{slice + 1}"

          # Renders the service, which registers every routed container with its target group.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] the resource block
          def service(settings)
            rule_ids = rule_specs(settings).map { |spec| spec[:id] }
            <<~YAML.chomp
              Service:
                Type: AWS::ECS::Service
                DependsOn: [#{(['Listener'] + rule_ids).join(', ')}]
                Properties:
                  ServiceName: !Sub "#{settings.prefix}-${EnvName}"
                  Cluster: !Ref Cluster
                  TaskDefinition: !Ref TaskDefinition
                  DesiredCount: !Ref DesiredCount
                  LaunchType: FARGATE
                  EnableExecuteCommand: true
                  NetworkConfiguration:
                    AwsvpcConfiguration:
                      AssignPublicIp: DISABLED
                      Subnets: [!Ref OwningSubnetAId, !Ref OwningSubnetBId]
                      SecurityGroups: [!Ref OwningSecurityGroupId]
                  LoadBalancers:
              #{indent(service_load_balancers(settings), 6)}
            YAML
          end

          # Renders the service's load balancer registrations.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [String] one list entry per routed container
          def service_load_balancers(settings)
            settings.containers.select(&:routed?).map do |c|
              "- ContainerName: #{c.name}\n  ContainerPort: #{c.port}\n  TargetGroupArn: !Ref #{c.logical}TargetGroup"
            end.join("\n")
          end
        end
      end
    end
  end
end
