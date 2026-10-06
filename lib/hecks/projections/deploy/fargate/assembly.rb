require_relative "yaml"
require_relative "settings"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # Fills the optional `# TMPL:<name>` sections of a rendered Fargate template with
        # what the plan calls for, or nothing when a world uses none of them.
        module Assembly
          module_function

          # Replaces every optional-section marker in a rendered template.
          def apply(template, plan, context)
            text = override_domain_env(template, plan.domain_env)
            sections(plan, context).each { |marker, block| text = Yaml.splice(text, marker, block) }
            check_duplicates!(text)
            text
          end

          def sections(plan, context)
            {
              "domain_essential"          => domain_essential_yaml(plan.layout.domain),
              "session_secret_properties" => session_secret_yaml(plan.extras[:session_secret]),
              "execution_database_grant"  => execution_grant_yaml(plan, context),
              "extra_execution_policies"  => Extras.policies_yaml(plan.extras[:execution_policies]),
              "extra_task_policies"       => task_policies_yaml(plan),
              "domain_env"                => domain_env_yaml(plan.domain_env),
              "extra_containers"          => lines(Containers.definitions_yaml(plan.layout, plan.ids[:log_group])),
              "target_group_attributes"   => Containers.target_group_attributes_yaml(plan.deregistration_delay),
              "extra_target_groups"       => target_groups_yaml(plan, context),
              "service_tuning"            => service_tuning_yaml(plan),
              "extra_load_balancers"      => Containers.load_balancers_yaml(plan.layout),
              "distribution"              => distribution_yaml(plan, context),
              "extra_resources"           => extra_resources_yaml(plan, context),
              "extra_outputs"             => outputs_yaml(plan)
            }
          end
          private_class_method :sections

          # Removes each default environment entry the world overrides, with the comments above it.
          def override_domain_env(template, domain_env)
            domain_env.keys.reduce(template) do |text, name|
              entry = /(?:^[ \t]*#.*\n)*^[ \t]*- Name: #{Regexp.escape(name)}\n[ \t]+Value: .*\n/
              if text.match?(entry)
                text.sub(entry, "")
              elsif domain_env[name].nil?
                raise ArgumentError,
                      "domain_env #{name} is nil, which removes a default variable, but the generator sets no #{name}"
              else
                text
              end
            end
          end
          private_class_method :override_domain_env

          def execution_grant_yaml(plan, context)
            return "" unless plan.execution_database_grant

            <<~GRANT
              - PolicyName: DbSecretRead
                PolicyDocument:
                  Version: '2012-10-17'
                  Statement:
                    - Effect: Allow
                      Action: secretsmanager:GetSecretValue
                      Resource: !Sub "${#{context[:db_secret_ref]}}"
            GRANT
          end
          private_class_method :execution_grant_yaml

          def domain_essential_yaml(domain)
            domain.essential.nil? ? "" : "Essential: #{domain.essential}\n"
          end
          private_class_method :domain_essential_yaml

          def domain_env_yaml(domain_env)
            domain_env.compact.map do |name, value|
              "- Name: #{name}\n  Value: #{Yaml.string(value)}\n"
            end.join
          end
          private_class_method :domain_env_yaml

          def session_secret_yaml(given)
            [("Name: #{given[:name]}\n" if given[:name]),
             ("Description: #{Yaml.string(given[:description])}\n" if given[:description])].compact.join
          end
          private_class_method :session_secret_yaml

          def task_policies_yaml(plan)
            Extras.policies_yaml(plan.extras[:task_policies]) + (plan.execute_command ? Extras.execute_command_policy_yaml : "")
          end
          private_class_method :task_policies_yaml

          def service_tuning_yaml(plan)
            lines = []
            lines << "EnableExecuteCommand: true" if plan.execute_command
            lines << "HealthCheckGracePeriodSeconds: #{plan.health_check_grace_period}" if plan.health_check_grace_period
            lines.empty? ? "" : "#{lines.join("\n")}\n"
          end
          private_class_method :service_tuning_yaml

          def target_groups_yaml(plan, context)
            blocks(
              [
                Containers.target_groups_yaml(plan.layout, context[:vpc_ref], plan.deregistration_delay),
                Containers.listener_rules_yaml(plan.layout, context[:listener_id])
              ].reject(&:empty?).join("\n\n")
            )
          end
          private_class_method :target_groups_yaml

          def distribution_yaml(plan, context)
            ids = { distribution_id: context[:distribution_id], alb_id: context[:alb_id] }
            plan.cdn ? Cdn.yaml(plan.cdn, **ids) : Cdn.default_yaml(**ids)
          end
          private_class_method :distribution_yaml

          def monitoring_context(plan, context, groups)
            { ids: plan.ids, stack_name: context[:stack_name], alb_id: context[:alb_id],
              distribution_id: context[:distribution_id], target_groups: groups }
          end
          private_class_method :monitoring_context

          def extra_resources_yaml(plan, context)
            alerts = plan.alerts
            groups = plan.layout.balanced.to_h { |container| [container.name, container.target_group_id] }
            monitoring = alerts ? Monitoring.yaml(alerts, monitoring_context(plan, context, groups)) : ""
            blocks([Containers.repositories_yaml(plan.layout), Extras.resources_yaml(plan.extras),
                    monitoring.rstrip].reject(&:empty?).join("\n\n"))
          end
          private_class_method :extra_resources_yaml

          # Adds one output per added container's repository, plus the cluster and service names a
          # deploy script needs to find the running service.
          def outputs_yaml(plan)
            listed = plan.layout.multi? ? container_outputs(plan) : ""
            alerts = plan.alerts ? "AlertsTopicArn:\n  Value: !Ref #{plan.ids[:alerts_topic]}\n" : ""
            listed + alerts + Extras.outputs_yaml(plan.extras[:outputs])
          end
          private_class_method :outputs_yaml

          def container_outputs(plan)
            repositories = plan.layout.all.map do |container|
              "#{Yaml.camel(container.name)}RepositoryUri:\n  Value: !GetAtt #{container.repository_id}.RepositoryUri\n"
            end
            cluster = "ClusterName:\n  Value: !Ref #{plan.ids[:cluster]}\n"
            service = "ServiceName:\n  Value: !GetAtt #{plan.ids[:service]}.Name\n"
            cluster + service + repositories.join
          end
          private_class_method :container_outputs

          # Joins resource blocks so the section ends in the blank line the template expects before
          # the next resource, and is empty when there is nothing to add.
          def blocks(text)
            text.empty? ? "" : "#{text}\n\n"
          end
          private_class_method :blocks

          # Ends a block in one newline, and leaves an empty block empty.
          def lines(text)
            text.empty? ? "" : "#{text}\n"
          end
          private_class_method :lines

          def check_duplicates!(template)
            resources = template[/^Resources:\n(.*?)^Outputs:/m, 1].to_s
            parameters = template[/^Parameters:\n(.*?)^Resources:/m, 1].to_s
            repeated = Yaml.duplicate_keys(resources) + Yaml.duplicate_keys(parameters)
            unless repeated.empty?
              raise ArgumentError, "logical id or parameter #{repeated.uniq.join(", ")} is declared more than once; " \
                                   "check logical_ids, containers and parameters for clashes"
            end
          end
          private_class_method :check_duplicates!
        end
      end
    end
  end
end
