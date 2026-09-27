require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The secrets and IAM roles of a preview stack.
        #
        # The task role reads the shared database secret and this preview's own
        # secrets and nothing owned by the main stack. The execution role also reads
        # the database secret, only so the one-shot task can receive the credentials
        # as container secrets.
        module AccessYaml
          extend YamlText

          module_function

          # Renders the secrets a preview generates: its session secret and the ones
          # containers declare.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<String>] one YAML resource block per secret
          def secrets(settings)
            [session_secret, *settings.containers.flat_map { |c| container_secrets(c) }]
          end

          # Renders the per-branch session secret the host reads at start.
          #
          # @return [String] the secret's resource block
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

          # Renders one generated secret per name a container declares.
          #
          # @param container [Containers::Entry] the container
          # @return [Array<String>] one resource block per declared secret name
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

          # Renders the task execution role and the task role.
          #
          # @param settings [Settings] the resolved preview settings
          # @return [Array<String>] the two role resource blocks
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

          # Renders the execution role, which pulls images and hands the one-shot task
          # its credentials.
          #
          # @param assume [String] the shared trust policy block
          # @return [String] the role's resource block
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

          # Renders the task role: read access to the shared database secret and this
          # preview's own secrets.
          #
          # @param assume [String] the shared trust policy block
          # @param settings [Settings] the resolved preview settings
          # @return [String] the role's resource block
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
