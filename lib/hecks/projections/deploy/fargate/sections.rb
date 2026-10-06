require_relative "yaml"
require_relative "settings"
require_relative "task_sections"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The text of each optional `# TMPL:<name>` section of a Fargate template, as the plan
        # calls for it: empty when a world uses none of it.
        module Sections
          extend TaskSections

          module_function

          # @param plan [Settings::Plan] the resolved settings
          # @param context [Hash{Symbol => String}] the ids the template's own resources go by
          # @return [Hash{String => String}] each marker's name and the text that replaces it
          def build(plan, context)
            task_sections(plan, context).merge(resource_sections(plan, context))
          end

          def task_sections(plan, context)
            {
              "domain_essential"          => domain_essential_yaml(plan.layout.domain),
              "session_secret_properties" => session_secret_yaml(plan.extras[:session_secret]),
              "execution_database_grant"  => execution_grant_yaml(plan, context),
              "extra_execution_policies"  => Extras.policies_yaml(plan.extras[:execution_policies]),
              "extra_task_policies"       => task_policies_yaml(plan),
              "domain_env"                => domain_env_yaml(plan.domain_env)
            }
          end
          private_class_method :task_sections

          def resource_sections(plan, context)
            {
              "extra_containers"        => lines(Containers.definitions_yaml(plan.layout, plan.ids[:log_group])),
              "target_group_attributes" => Containers.target_group_attributes_yaml(plan.deregistration_delay),
              "extra_target_groups"     => target_groups_yaml(plan, context),
              "service_tuning"          => service_tuning_yaml(plan),
              "extra_load_balancers"    => Containers.load_balancers_yaml(plan.layout),
              "distribution"            => distribution_yaml(plan, context),
              "extra_resources"         => extra_resources_yaml(plan, context),
              "extra_outputs"           => outputs_yaml(plan)
            }
          end
          private_class_method :resource_sections

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
        end
      end
    end
  end
end
