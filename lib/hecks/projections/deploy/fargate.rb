require_relative "../../projector"
require_relative "shared"
require_relative "scripts"
require_relative "preview"
require_relative "text_template"
require_relative "fargate/settings"
require_relative "fargate/assembly"
require_relative "fargate/stack"

module Hecks
  module Projections
    module Deploy
      # The AWS Fargate deploy target for `deployed_to("AwsFargate")`: renders a
      # CloudFormation stack (ECR, ECS, ALB, CloudFront) plus the shared VPC/RDS `Shared` builds.
      module Fargate
        extend Projector::Target

        projects_as :aws_fargate, needs_world: true, emits: :files

        module_function

        # Generates `template.yaml`, `Makefile`, `Dockerfile`, and — unless
        # this domain borrows another domain's RDS instance — `bastion.yaml`.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the domain's own booted chapter
        # @param options [Hash] generation options; same shape as `Lambda.call`'s
        # @return [Hash{String => String}] the generated file contents, keyed by filename
        # @raise [ArgumentError] if the domain's deploy settings conflict
        def call(bluebook:, options: {})
          stack = Stack.new(options)
          files = { "template.yaml" => template_yaml(stack) }
          files["bastion.yaml"] = bastion_yaml(stack) unless stack.shared
          files["Dockerfile"] = TextTemplate.render_from("fargate/Dockerfile.tmpl", stack)
          files["Makefile"] = TextTemplate.render_from("fargate/Makefile.tmpl", stack)
          with_previews_and_scripts(files, stack)
        end

        # Renders `template.yaml`: the template, then the sections that are spliced in after it
        # renders, not interpolated inside it, since `<<~` dedents from raw source before a value
        # is placed, so a multi-line value could not be reindented a second time.
        #
        # @param stack [Stack] the stack the world declares
        # @return [String] the CloudFormation template
        def template_yaml(stack)
          text = TextTemplate.render_from("fargate/template.yaml.tmpl", stack)
          text = splice_database_env(text, stack)
          # Indented by the marker's own rendered column, never a hand-computed one: the template
          # dedents after interpolation, so a source-counted column lands at the wrong depth.
          text = Yaml.splice(text, "oauth_task_policy", "#{stack.oauth_task_policy_yaml}\n")
          text = Yaml.splice(text, "oauth_task_env", "#{stack.oauth_task_env_yaml}\n")
          assemble(splice_cross_domain_policies(text, stack), stack)
        end

        def assemble(text, stack)
          Assembly.apply(text, stack.plan, stack.assembly_context)
        rescue ArgumentError => e
          raise ArgumentError, "#{stack.world_file}'s deployed_to(\"AwsFargate\"): #{e.message}"
        end
        private_class_method :assemble

        # Opt-in per-branch previews: nothing is added unless the domain declares a `preview`
        # setting under deployed_to("AwsFargate"). See Preview's own header for the keys.
        def with_previews_and_scripts(files, stack)
          files.merge!(Preview.call(deploy_settings: stack.deploy_settings, main: stack.preview_main))
          Scripts.extend_files(files, deploy_settings: stack.deploy_settings, plan: stack.plan,
                                      stack_name: stack.stack_name, region: stack.region)
        end
        private_class_method :with_previews_and_scripts

        def splice_database_env(text, stack)
          text.sub(/^([ \t]*)# TMPL:db_env\n/) { stack.db_env_yaml(Regexp.last_match(1)) }
        end
        private_class_method :splice_database_env

        def splice_cross_domain_policies(text, stack)
          text.sub(/^([ \t]*)# TMPL:cross_domain_fargate_policies\n/) do
            stack.cross_domain_targets.empty? ? "" : stack.cross_domain_policy_yaml(Regexp.last_match(1))
          end
        end
        private_class_method :splice_cross_domain_policies

        def bastion_yaml(stack)
          Shared.bastion_yaml(stack.network, domain: stack.domain, stack_name: stack.stack_name,
                                             bastion_parameters: stack.bastion_parameters)
        end
        private_class_method :bastion_yaml
      end
    end
  end
end
