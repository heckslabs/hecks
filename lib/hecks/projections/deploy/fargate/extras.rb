require_relative "check"
require_relative "yaml"
require_relative "extras/reading"
require_relative "extras/rendering"

module Hecks
  module Projections
    module Deploy
      module Fargate
        # The extra resources, parameters, outputs and IAM grants a stack can declare beyond
        # what the generator always makes; settings are documented in the DSL reference.
        module Extras
          BUCKET_KEYS = [:id, :name_prefix, :public_read, :cors_origins].freeze
          SECRET_KEYS = [:id, :name, :description, :key, :length].freeze
          POLICY_KEYS = [:name, :statements].freeze
          STATEMENT_KEYS = [:effect, :actions, :resources].freeze
          PARAMETER_KEYS = [:type, :default, :description, :no_echo].freeze
          PARAMETER_TYPE = /\A(String|Number|CommaDelimitedList|List<Number>|AWS::[A-Za-z0-9:]+|AWS::SSM::Parameter::Value<[^>]+>)\z/
          EXEC_ACTIONS = %w[ssmmessages:CreateControlChannel ssmmessages:CreateDataChannel
                            ssmmessages:OpenControlChannel ssmmessages:OpenDataChannel].freeze

          extend Reading
          extend Rendering

          module_function

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
            blocks = extras[:buckets].flat_map { |bucket| bucket_blocks(bucket) }
            blocks.concat(extras[:secrets].map { |secret| secret_yaml(secret) }).join("\n\n")
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
        end
      end
    end
  end
end
