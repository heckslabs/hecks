require "json"
require_relative "../text_template"
require_relative "yaml_text"

module Hecks
  module Projections
    module Deploy
      module Preview
        # The task definitions of a preview stack: the containers it runs and the
        # one-shot task that creates its database.
        module TaskYaml
          extend YamlText

          module_function

          # The one-shot task's script. Idempotent, and refuses names the preview must never touch.
          def db_init_script
            TextTemplate.render("preview/db_init_script.sh.tmpl")
          end

          # The database credentials as container secrets, so the password never appears as a plain
          # value in the task definition.
          def db_init_secrets
            TextTemplate.render("preview/db_init_secrets.tmpl").chomp
          end

          # Also renders the drop path, taken when `ACTION` is `drop`.
          def db_init_task(settings)
            TextTemplate.render(
              "preview/db_init_task.tmpl",
              prefix: settings.prefix, image: settings.db_init_image, script: indent(db_init_script.chomp, 12),
              protected: JSON.generate(settings.protected_databases.join(" ")), secrets: indent(db_init_secrets, 8)
            ).chomp
          end

          def task_definition(settings)
            containers = settings.containers.map { |c| container_definition(settings, c) }.join("\n")
            TextTemplate.render("preview/task_definition.tmpl", prefix: settings.prefix, cpu: settings.cpu,
                                                                memory: settings.memory,
                                                                containers: indent(containers, 6)).chomp
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
            TextTemplate.render("preview/log_options.tmpl", container: container.name)
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
            pairs.merge(own_environment(container)).to_a
          end

          def own_environment(container)
            secrets = container.secrets.to_h { |name| [name, "!Ref #{secret_id(container, name)}"] }
            secrets.merge(container.environment.transform_values { |value| scalar(value) })
          end

          def host_environment(settings)
            main = settings.main
            host_serving(settings, main).merge(host_artifacts(main)).merge(host_optional(settings, main))
          end

          def host_serving(settings, main)
            {
              "HECKS_DOMAIN" => scalar(main.fetch(:domain)), "HECKS_ERA" => scalar("1"),
              "PORT" => scalar(settings.host.port.to_s), "BIND" => scalar("0.0.0.0"),
              "HECKS_SERVE_MODE" => scalar("1"), "HECKS_WEB" => scalar(main.fetch(:web))
            }
          end

          def host_artifacts(main)
            {
              "HECKS_WASM_PATH" => scalar(main.fetch(:wasm_path)), "HECKS_IR_PATH" => scalar(main.fetch(:ir_path)),
              "SESSION_SECRET_ARN" => "!Ref SessionSecret", "HECKS_CHECKOUT_DOMAIN" => scalar(main.fetch(:domain))
            }
          end

          def host_optional(settings, main)
            pairs = {}
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
