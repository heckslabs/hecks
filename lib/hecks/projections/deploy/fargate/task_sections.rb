require_relative "yaml"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The text of the optional sections that sit inside the task definition and the service:
        # the domain container's own settings, policies and tuning. Extended onto `Sections`.
        module TaskSections
          private

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

          def domain_essential_yaml(domain)
            domain.essential.nil? ? "" : "Essential: #{domain.essential}\n"
          end

          def domain_env_yaml(domain_env)
            domain_env.compact.map do |name, value|
              "- Name: #{name}\n  Value: #{Yaml.string(value)}\n"
            end.join
          end

          def session_secret_yaml(given)
            [("Name: #{given[:name]}\n" if given[:name]),
             ("Description: #{Yaml.string(given[:description])}\n" if given[:description])].compact.join
          end

          def task_policies_yaml(plan)
            execute = plan.execute_command ? Extras.execute_command_policy_yaml : ""
            "#{Extras.policies_yaml(plan.extras[:task_policies])}#{execute}"
          end

          def service_tuning_yaml(plan)
            lines = []
            lines << "EnableExecuteCommand: true" if plan.execute_command
            lines << "HealthCheckGracePeriodSeconds: #{plan.health_check_grace_period}" if plan.health_check_grace_period
            lines.empty? ? "" : "#{lines.join("\n")}\n"
          end
        end
      end
    end
  end
end
