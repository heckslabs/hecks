require_relative "check"
require_relative "yaml"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The extra resources, parameters, outputs and IAM grants a stack can declare beyond
        # what the generator always makes; settings are documented in the DSL reference.
        module Extras
          module_function

          BUCKET_KEYS = [:id, :name_prefix, :public_read, :cors_origins].freeze
          SECRET_KEYS = [:id, :name, :description, :key, :length].freeze
          POLICY_KEYS = [:name, :statements].freeze
          STATEMENT_KEYS = [:effect, :actions, :resources].freeze
          PARAMETER_KEYS = [:type, :default, :description, :no_echo].freeze
          PARAMETER_TYPE = /\A(String|Number|CommaDelimitedList|List<Number>|AWS::[A-Za-z0-9:]+|AWS::SSM::Parameter::Value<[^>]+>)\z/
          EXEC_ACTIONS = %w[ssmmessages:CreateControlChannel ssmmessages:CreateDataChannel
                            ssmmessages:OpenControlChannel ssmmessages:OpenDataChannel].freeze

          # Reads and checks the resource-declaring settings.
          def normalize(settings)
            {
              buckets:            buckets(settings.fetch(:buckets, [])),
              secrets:            secrets(settings.fetch(:generated_secrets, [])),
              session_secret:     session_secret(settings[:session_secret]),
              task_policies:      policies(settings.fetch(:task_policies, []), "task_policies"),
              execution_policies: policies(settings.fetch(:execution_policies, []), "execution_policies"),
              parameters:         parameters(settings.fetch(:parameters, {})),
              outputs:            outputs(settings.fetch(:outputs, {}))
            }
          end

          # Renders the buckets and generated secrets.
          def resources_yaml(extras)
            (extras[:buckets].flat_map { |bucket| bucket_blocks(bucket) } + extras[:secrets].map do |secret|
              secret_yaml(secret)
            end).join("\n\n")
          end

          # Renders extra policies as entries of a role's `Policies` list.
          def policies_yaml(policies)
            policies.map { |policy| policy_yaml(policy) }.join
          end

          # Renders the policy that lets `aws ecs execute-command` open a session in a container.
          def execute_command_policy_yaml
            policy_yaml(
              name:       "EcsExecDebug",
              statements: [{ effect: "Allow", actions: EXEC_ACTIONS, resources: ["*"] }]
            )
          end

          # Renders the extra template parameters.
          def parameters_yaml(parameters)
            parameters.map do |name, given|
              lines = ["#{name}:", "  Type: #{given[:type]}"]
              lines << "  Default: #{Yaml.scalar(given[:default])}" if given.key?(:default)
              lines << "  Description: #{Yaml.string(given[:description])}" if given[:description]
              lines << "  NoEcho: true" if given[:no_echo]
              "#{lines.join("\n")}\n"
            end.join
          end

          # Renders the extra template outputs.
          def outputs_yaml(outputs)
            outputs.map { |name, value| "#{name}:\n  Value: #{Yaml.string(value)}\n" }.join
          end

          def buckets(entries)
            Check.hashes!(entries, "buckets", allowed: BUCKET_KEYS, required: [:id, :name_prefix]).map do |entry|
              {
                id:           Check.logical_id!(entry[:id], "buckets id"),
                name_prefix:  Check.resource_name!(entry[:name_prefix], "buckets name_prefix").downcase,
                public_read:  Check.boolean!(entry.fetch(:public_read, false), "buckets public_read"),
                cors_origins: Check.strings!(entry.fetch(:cors_origins, []), "buckets cors_origins")
              }
            end
          end
          private_class_method :buckets

          def secrets(entries)
            Check.hashes!(entries, "generated_secrets", allowed: SECRET_KEYS, required: [:id, :name]).map do |entry|
              {
                id:          Check.logical_id!(entry[:id], "generated_secrets id"),
                name:        Check.resource_name!(entry[:name], "generated_secrets name"),
                description: entry[:description]&.to_s,
                key:         Check.resource_name!(entry.fetch(:key, "secret"), "generated_secrets key"),
                length:      Check.integer!(entry.fetch(:length, 64), "generated_secrets length", range: 8..512)
              }
            end
          end
          private_class_method :secrets

          def session_secret(value)
            return {} if value.nil?

            given = Check.hash!(value, "session_secret", allowed: [:name, :description])
            { name:        given[:name] && Check.resource_name!(given[:name], "session_secret name"),
              description: given[:description]&.to_s }.compact
          end
          private_class_method :session_secret

          def policies(entries, where)
            Check.hashes!(entries, where, allowed: POLICY_KEYS, required: [:name, :statements]).map do |entry|
              statements = Check.hashes!(entry[:statements], "#{where}[#{entry[:name]}] statements",
                                         allowed: STATEMENT_KEYS, required: [:actions, :resources])
              {
                name:       Check.logical_id!(entry[:name], "#{where} name"),
                statements: statements.map do |statement|
                  {
                    effect:    Check.one_of!(statement.fetch(:effect, "Allow"), "#{where} effect", %w[Allow Deny]),
                    actions:   Check.strings!(statement[:actions], "#{where} actions", min: 1),
                    resources: Check.strings!(statement[:resources], "#{where} resources", min: 1)
                  }
                end
              }
            end
          end
          private_class_method :policies

          def parameters(map)
            raise ArgumentError, "parameters must be a hash of name to settings, got #{map.inspect}" unless map.is_a?(Hash)

            map.to_h do |name, entry|
              key = Check.logical_id!(name, "parameters name")
              given = Check.hash!(entry, "parameters.#{key}", allowed: PARAMETER_KEYS, required: [:type])
              unless PARAMETER_TYPE.match?(given[:type].to_s)
                raise ArgumentError,
                      "parameters.#{key} type #{given[:type].inspect} is not a CloudFormation parameter type"
              end

              [key, given.merge(type: given[:type].to_s, no_echo: given[:no_echo] ? true : false)]
            end
          end
          private_class_method :parameters

          def outputs(map)
            raise ArgumentError, "outputs must be a hash of name to value, got #{map.inspect}" unless map.is_a?(Hash)

            map.to_h do |name, value|
              raise ArgumentError, "outputs.#{name} needs a value" if value.nil?

              [Check.logical_id!(name, "outputs name"), value]
            end
          end
          private_class_method :outputs

          def bucket_blocks(bucket)
            blocks = [bucket_yaml(bucket)]
            blocks << bucket_policy_yaml(bucket) if bucket[:public_read]
            blocks
          end
          private_class_method :bucket_blocks

          def bucket_yaml(bucket)
            lines = ["#{bucket[:id]}:", "  Type: AWS::S3::Bucket", "  Properties:",
                     "    BucketName: !Sub \"#{bucket[:name_prefix]}-${AWS::AccountId}\""]
            lines.concat(public_access_lines) if bucket[:public_read]
            lines.concat(cors_lines(bucket[:cors_origins])) unless bucket[:cors_origins].empty?
            lines.join("\n")
          end
          private_class_method :bucket_yaml

          def public_access_lines
            ["    PublicAccessBlockConfiguration:", "      BlockPublicAcls: false", "      BlockPublicPolicy: false",
             "      IgnorePublicAcls: false", "      RestrictPublicBuckets: false"]
          end
          private_class_method :public_access_lines

          def cors_lines(origins)
            ["    CorsConfiguration:", "      CorsRules:", "        - AllowedOrigins: #{Yaml.flow_list(origins)}",
             "          AllowedMethods: [GET]", "          AllowedHeaders: [\"*\"]"]
          end
          private_class_method :cors_lines

          def bucket_policy_yaml(bucket)
            <<~POLICY.rstrip
              #{bucket[:id]}Policy:
                Type: AWS::S3::BucketPolicy
                Properties:
                  Bucket: !Ref #{bucket[:id]}
                  PolicyDocument:
                    Version: "2012-10-17"
                    Statement:
                      - Effect: Allow
                        Principal: "*"
                        Action: s3:GetObject
                        Resource: !Sub "${#{bucket[:id]}.Arn}/*"
            POLICY
          end
          private_class_method :bucket_policy_yaml

          def secret_yaml(secret)
            lines = ["#{secret[:id]}:", "  Type: AWS::SecretsManager::Secret", "  Properties:", "    Name: #{secret[:name]}"]
            lines << "    Description: #{Yaml.string(secret[:description])}" if secret[:description]
            lines.push("    GenerateSecretString:", "      SecretStringTemplate: '{}'",
                       "      GenerateStringKey: #{secret[:key]}", "      PasswordLength: #{secret[:length]}",
                       "      ExcludePunctuation: true")
            lines.join("\n")
          end
          private_class_method :secret_yaml

          def policy_yaml(policy)
            lines = ["- PolicyName: #{policy[:name]}", "  PolicyDocument:", "    Version: '2012-10-17'", "    Statement:"]
            policy[:statements].each do |statement|
              lines << "      - Effect: #{statement[:effect]}"
              lines.concat(statement_list("Action", statement[:actions]))
              lines.concat(statement_list("Resource", statement[:resources].map { |resource| Yaml.string(resource) }))
            end
            "#{lines.join("\n")}\n"
          end
          private_class_method :policy_yaml

          # One entry is written as a scalar, the form IAM policies usually take; more are a list.
          def statement_list(key, values)
            return ["        #{key}: #{values.first}"] if values.one?

            ["        #{key}:"] + values.map { |value| "          - #{value}" }
          end
          private_class_method :statement_list
        end
      end
    end
  end
end
