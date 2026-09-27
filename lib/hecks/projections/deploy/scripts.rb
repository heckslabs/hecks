require "shellwords"
require_relative "scripts/settings"

module Hecks
  module Projections
    module Deploy
      # The hosting scripts an AWS Fargate deploy ships beside its template: the steps an
      # operator runs after `make deploy` has created the stack.
      module Scripts
        # Container names, repositories and image-tag parameters come from `plan`, not
        # from a setting here; rename them in `Fargate::Settings::Plan` and these scripts follow.
        SCRIPT_DIR = File.join(__dir__, "scripts").freeze

        module_function

        # Adds the hosting scripts to a Fargate file map when the domain opts in.
        #
        # @param files [Hash{String => String}] the Fargate target's own files, keyed by path
        # @param deploy_settings [Hash{Symbol => Object}] the world's `deployed_to("AwsFargate")`
        #   settings
        # @param plan [Fargate::Settings::Plan] the template generator's resolved settings, the
        #   source of every container, repository and parameter name
        # @param stack_name [String] the CloudFormation stack name
        # @param region [String] the validated AWS region
        # @return [Hash{String => String}] `files` itself when the domain has not opted in, else
        #   a copy with the scripts added and the `Makefile` including `hosting.mk`
        # @raise [ArgumentError] if a hosting setting is missing or invalid; see `Settings`
        def extend_files(files, deploy_settings:, plan:, stack_name:, region:)
          return files unless deploy_settings[:hosting_scripts] == true

          settings = Settings.new(deploy_settings: deploy_settings, plan: plan,
                                  stack_name: stack_name, region: region)
          files.merge(
            "Makefile"              => "#{files.fetch('Makefile')}\ninclude hosting.mk\n",
            "hosting.mk"            => hosting_mk(settings),
            "deploy-service.sh"     => deploy_service_sh(settings),
            "smoke-after-deploy.sh" => smoke_after_deploy_sh(settings),
            "expected-era"          => expected_era(settings)
          )
        end

        # Renders `deploy-service.sh`.
        #
        # @param settings [Settings] the checked hosting settings
        # @return [String] the script
        def deploy_service_sh(settings)
          render("deploy-service.sh.tmpl", "SETTINGS" => stack_constants(settings),
                                           "SERVICES" => services_block(settings))
        end

        # Renders `smoke-after-deploy.sh`.
        #
        # @param settings [Settings] the checked hosting settings
        # @return [String] the script
        def smoke_after_deploy_sh(settings)
          smoke = [
            "REPO=\"${REPO:-#{settings.smoke_repo}}\"",
            "WORKFLOW=\"${WORKFLOW:-#{settings.smoke_workflow}}\"",
            "SMOKE_REF=\"${SMOKE_REF:-#{settings.smoke_ref}}\""
          ]
          render("smoke-after-deploy.sh.tmpl", "SETTINGS" => [stack_constants(settings), *smoke].join("\n"))
        end

        # Renders the `expected-era` allow-list.
        #
        # @param settings [Settings] the checked hosting settings
        # @return [String] the header comment followed by one era id per line
        def expected_era(settings)
          header = File.read(File.join(SCRIPT_DIR, "expected-era.header"))
          "#{([header.chomp, ''] + settings.expected_eras).join("\n")}\n"
        end

        # Renders `hosting.mk`.
        #
        # @param settings [Settings] the checked hosting settings
        # @return [String] the Makefile fragment
        def hosting_mk(settings)
          render("hosting.mk.tmpl", "RELEASE" => settings.hecks_release, "SOURCE" => settings.hecks_source,
                                    "CACHE_DIR" => settings.hecks_cache_dir, "URL" => settings.public_url.to_s,
                                    "SERVICE" => settings.containers.first.name)
        end

        def stack_constants(settings)
          {
            "REGION" => settings.region, "CLUSTER" => settings.cluster,
            "ECS_SERVICE" => settings.service, "STACK" => settings.stack
          }.map { |name, value| "#{name}=#{Shellwords.escape(value)}" }.join("\n")
        end

        def services_block(settings)
          arms = settings.containers.map do |container|
            repository = Shellwords.escape(container.repository_name)
            parameter = Shellwords.escape(container.tag_parameter)
            "    #{Shellwords.escape(container.name)}) ECR_REPOSITORY=#{repository}; CFN_PARAM_KEY=#{parameter} ;;"
          end
          <<~BASH.chomp
            SERVICES='#{settings.containers.map(&:name).join(' ')}'

            # Sets ECR_REPOSITORY and CFN_PARAM_KEY for one service, or exits.
            resolve_service() {
              case "$1" in
            #{arms.join("\n")}
                *) echo "unknown service '$1', must be one of: ${SERVICES}" >&2; exit 1 ;;
              esac
            }
          BASH
        end

        def render(template, values)
          text = File.read(File.join(SCRIPT_DIR, template))
          values.reduce(text) { |out, (marker, value)| out.gsub(/#?@@#{marker}@@/) { value } }
        end

        private_class_method :stack_constants, :services_block, :render
      end
    end
  end
end
