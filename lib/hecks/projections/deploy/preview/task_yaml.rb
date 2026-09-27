require "json"
require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The task definitions of a preview stack: the containers it runs and the
        # one-shot task that creates its database.
        module TaskYaml
          # The one-shot task's script. Idempotent, and refuses names the preview must never touch.
          DB_INIT_SCRIPT = <<~SH.freeze
            set -eu
            case "$TARGET_DB" in
              ""|*[!a-z0-9_]*) echo "refusing TARGET_DB '$TARGET_DB': lowercase letters, digits and underscores only" >&2; exit 1 ;;
            esac
            [ "${#TARGET_DB}" -le 63 ] || { echo "refusing TARGET_DB '$TARGET_DB': longer than 63 characters" >&2; exit 1; }
            for protected in $PROTECTED_DATABASES; do
              [ "$TARGET_DB" != "$protected" ] || { echo "refusing to manage the protected database '$protected'" >&2; exit 1; }
            done
            export PGSSLMODE=require PGCONNECT_TIMEOUT=10
            found=$(psql -h "$DB_HOST" -U "$PGUSER" -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$TARGET_DB'")
            if [ "${ACTION:-create}" = "drop" ]; then
              if [ "$found" = "1" ]; then
                psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -U "$PGUSER" -d postgres -c "DROP DATABASE \\"$TARGET_DB\\" WITH (FORCE)"
                echo "dropped database $TARGET_DB"
              else
                echo "database $TARGET_DB does not exist"
              fi
            elif [ "$found" = "1" ]; then
              echo "database $TARGET_DB already exists"
            else
              psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -U "$PGUSER" -d postgres -c "CREATE DATABASE \\"$TARGET_DB\\""
              echo "created database $TARGET_DB"
            fi
          SH

          # The database credentials as container secrets, so the password never appears as a plain
          # value in the task definition.
          DB_INIT_SECRETS = <<~YAML.chomp.freeze
            Secrets:
              - Name: PGUSER
                ValueFrom: !Sub "${OwningDatabaseSecretArn}:username::"
              - Name: PGPASSWORD
                ValueFrom: !Sub "${OwningDatabaseSecretArn}:password::"
          YAML

          extend YamlText

          module_function

          # Also renders the drop path, taken when `ACTION` is `drop`.
          def db_init_task(settings)
            <<~YAML.chomp
              # Run by preview.sh (`aws ecs run-task`) after the images are pushed and before the
              # service scales up: the database instance is reachable only from inside the VPC, so
              # this is the one place a laptop-driven deploy can run CREATE DATABASE. Idempotent.
              DbInitTaskDefinition:
                Type: AWS::ECS::TaskDefinition
                Properties:
                  Family: !Sub "#{settings.prefix}-${EnvName}-dbinit"
                  RequiresCompatibilities: [FARGATE]
                  NetworkMode: awsvpc
                  Cpu: "256"
                  Memory: "512"
                  RuntimePlatform:
                    CpuArchitecture: ARM64
                    OperatingSystemFamily: LINUX
                  ExecutionRoleArn: !GetAtt ExecutionRole.Arn
                  TaskRoleArn: !GetAtt TaskRole.Arn
                  ContainerDefinitions:
                    - Name: dbinit
                      Image: #{settings.db_init_image}
                      Essential: true
                      Command:
                        - sh
                        - -c
                        - |
              #{indent(DB_INIT_SCRIPT.chomp, 12)}
                      LogConfiguration:
                        LogDriver: awslogs
                        Options:
                          awslogs-group: !Ref LogGroup
                          awslogs-region: !Ref AWS::Region
                          awslogs-stream-prefix: dbinit
                      Environment:
                        - Name: DB_HOST
                          Value: !Ref OwningDatabaseEndpoint
                        - Name: TARGET_DB
                          Value: !Ref DbName
                        - Name: PROTECTED_DATABASES
                          Value: #{JSON.generate(settings.protected_databases.join(' '))}
              #{indent(DB_INIT_SECRETS, 8)}
            YAML
          end

          def task_definition(settings)
            <<~YAML.chomp
              TaskDefinition:
                Type: AWS::ECS::TaskDefinition
                Properties:
                  Family: !Sub "#{settings.prefix}-${EnvName}"
                  RequiresCompatibilities: [FARGATE]
                  NetworkMode: awsvpc
                  Cpu: "#{settings.cpu}"
                  Memory: "#{settings.memory}"
                  RuntimePlatform:
                    CpuArchitecture: ARM64
                    OperatingSystemFamily: LINUX
                  ExecutionRoleArn: !GetAtt ExecutionRole.Arn
                  TaskRoleArn: !GetAtt TaskRole.Arn
                  ContainerDefinitions:
              #{indent(settings.containers.map { |c| container_definition(settings, c) }.join("\n"), 6)}
            YAML
          end

          def container_definition(settings, container)
            lines = [
              "- Name: #{container.name}",
              %(  Image: !Sub "${#{container.logical}Repository.RepositoryUri}:${#{container.logical}ImageTag}"),
              "  Essential: true"
            ]
            lines += ["  PortMappings:", "    - ContainerPort: #{container.port}"] if container.routed?
            lines += ["  LogConfiguration:", indent(log_options(container), 4).chomp]
            lines += ["  Environment:", indent(environment_yaml(settings, container), 4).chomp]
            lines.join("\n")
          end

          def log_options(container)
            <<~YAML
              LogDriver: awslogs
              Options:
                awslogs-group: !Ref LogGroup
                awslogs-region: !Ref AWS::Region
                awslogs-stream-prefix: #{container.name}
            YAML
          end

          def environment_yaml(settings, container)
            environment_pairs(settings, container).map do |name, value|
              "- Name: #{name}\n  Value: #{value}"
            end.join("\n")
          end

          # The container's own `environment` wins over a generated entry of the same name.
          def environment_pairs(settings, container)
            pairs = { "PORT" => scalar(container.port.to_s) }
            pairs.merge!(host_environment(settings)) if container.host
            pairs.merge!(database_environment) if container.host || container.database
            container.secrets.each { |name| pairs[name] = "!Ref #{secret_id(container, name)}" }
            container.environment.each { |name, value| pairs[name] = scalar(value) }
            pairs.to_a
          end

          def host_environment(settings)
            main = settings.main
            pairs = {
              "HECKS_DOMAIN" => scalar(main.fetch(:domain)), "HECKS_ERA" => scalar("1"),
              "PORT" => scalar(settings.host.port.to_s), "BIND" => scalar("0.0.0.0"),
              "HECKS_SERVE_MODE" => scalar("1"), "HECKS_WEB" => scalar(main.fetch(:web)),
              "HECKS_WASM_PATH" => scalar(main.fetch(:wasm_path)), "HECKS_IR_PATH" => scalar(main.fetch(:ir_path)),
              "SESSION_SECRET_ARN" => "!Ref SessionSecret", "HECKS_CHECKOUT_DOMAIN" => scalar(main.fetch(:domain))
            }
            pairs["HECKS_SCHEMA"] = scalar(main[:schema]) if main[:schema]
            pairs["HECKS_SESSION_COOKIE"] = scalar(settings.session_cookie) if settings.session_cookie
            pairs
          end

          def database_environment
            {
              "DB_HOST" => "!Ref OwningDatabaseEndpoint", "DB_NAME" => "!Ref DbName",
              "DB_SECRET_ARN" => "!Ref OwningDatabaseSecretArn"
            }
          end
        end
      end
    end
  end
end
