require_relative "yaml"
require_relative "settings"
require_relative "sections"

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
            Sections.build(plan, context).each { |marker, block| text = Yaml.splice(text, marker, block) }
            check_duplicates!(text)
            text
          end

          # Removes each default environment entry the world overrides, with the comments above it.
          def override_domain_env(template, domain_env)
            domain_env.keys.reduce(template) { |text, name| without_default(text, name, domain_env[name]) }
          end
          private_class_method :override_domain_env

          def without_default(text, name, value)
            entry = /(?:^[ \t]*#.*\n)*^[ \t]*- Name: #{Regexp.escape(name)}\n[ \t]+Value: .*\n/
            return text.sub(entry, "") if text.match?(entry)
            return text unless value.nil?

            raise ArgumentError, "domain_env #{name} is nil, which removes a default variable, but the generator sets no #{name}"
          end
          private_class_method :without_default

          def check_duplicates!(template)
            resources = template[/^Resources:\n(.*?)^Outputs:/m, 1].to_s
            parameters = template[/^Parameters:\n(.*?)^Resources:/m, 1].to_s
            repeated = Yaml.duplicate_keys(resources) + Yaml.duplicate_keys(parameters)
            return if repeated.empty?

            raise ArgumentError, "logical id or parameter #{repeated.uniq.join(", ")} is declared more than once; " \
                                 "check logical_ids, containers and parameters for clashes"
          end
          private_class_method :check_duplicates!
        end
      end
    end
  end
end
