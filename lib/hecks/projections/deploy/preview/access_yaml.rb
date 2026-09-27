require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The secrets and IAM roles of a preview stack, scoped away from the main stack.
        module AccessYaml
          extend YamlText

          module_function

          def secrets(settings)
            [session_secret, *settings.containers.flat_map { |c| container_secrets(c) }]
          end

          def session_secret
            <<~YAML.chomp
              # No explicit Name: Secrets Manager keeps a deleted secret through its recovery window,
              # and a fixed name would make destroy followed by deploy on one branch fail.
              SessionSecret:
                Type: AWS::SecretsManager::Secret
                Properties:
                  Description: !Sub "Session secret of the ${EnvName} preview."
                  GenerateSecretString:
                    SecretStringTemplate: '{}'
                    GenerateStringKey: session_secret
                    PasswordLength: 64
                    ExcludePunctuation: true
            YAML
          end

          def container_secrets(container)
            container.secrets.map do |name|
              <<~YAML.chomp
                #{secret_id(container, name)}:
                  Type: AWS::SecretsManager::Secret
                  Properties:
                    Description: !Sub "#{name} of the ${EnvName} preview's #{container.name} container."
                    GenerateSecretString:
                      SecretStringTemplate: '{}'
                      GenerateStringKey: secret
                      PasswordLength: 64
                      ExcludePunctuation: true
              YAML
            end
          end

          def roles(settings)
            assume = <<~YAML.chomp
              AssumeRolePolicyDocument:
                Version: '2012-10-17'
                Statement:
                  - Effect: Allow
                    Principal: { Service: ecs-tasks.amazonaws.com }
                    Action: sts:AssumeRole
            YAML
            [execution_role(assume), task_role(assume, settings)]
          end

          def execution_role(assume)
            <<~YAML.chomp
              # The execution role reads the database secret only so the one-shot task can be given
              # its credentials as container secrets.
              ExecutionRole:
                Type: AWS::IAM::Role
                Properties:
              #{indent(assume, 4)}
                  ManagedPolicyArns:
                    - arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
                  Policies:
                    - PolicyName: SharedDatabaseSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Ref OwningDatabaseSecretArn
            YAML
          end

          def task_role(assume, settings)
            readable = ["SessionSecret", *settings.containers.flat_map { |c| c.secrets.map { |n| secret_id(c, n) } }]
            <<~YAML.chomp
              # Reads the shared database secret (it connects with it and creates its database) and
              # this preview's own secrets; nothing owned by the main stack.
              TaskRole:
                Type: AWS::IAM::Role
                Properties:
              #{indent(assume, 4)}
                  Policies:
                    - PolicyName: SharedDatabaseSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource: !Ref OwningDatabaseSecretArn
                    - PolicyName: PreviewSecretRead
                      PolicyDocument:
                        Version: '2012-10-17'
                        Statement:
                          - Effect: Allow
                            Action: secretsmanager:GetSecretValue
                            Resource:
              #{indent(readable.map { |id| "- !Ref #{id}" }.join("\n"), 16)}
            YAML
          end
        end
      end
    end
  end
end
