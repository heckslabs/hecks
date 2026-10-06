require_relative "../text_template"
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
            TextTemplate.render("preview/session_secret.tmpl").chomp
          end

          def container_secrets(container)
            container.secrets.map do |name|
              TextTemplate.render("preview/container_secret.tmpl", id: secret_id(container, name), name: name,
                                                                   container: container.name).chomp
            end
          end

          def roles(settings)
            assume = TextTemplate.render("preview/assume_role.tmpl").chomp
            [execution_role(assume), task_role(assume, settings)]
          end

          def execution_role(assume)
            TextTemplate.render("preview/execution_role.tmpl", assume: indent(assume, 4)).chomp
          end

          def task_role(assume, settings)
            readable = ["SessionSecret", *settings.containers.flat_map { |c| c.secrets.map { |n| secret_id(c, n) } }]
            refs = readable.map { |id| "- !Ref #{id}" }.join("\n")
            TextTemplate.render("preview/task_role.tmpl", assume: indent(assume, 4), readable: indent(refs, 16)).chomp
          end
        end
      end
    end
  end
end
