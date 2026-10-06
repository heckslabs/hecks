require "shellwords"
require_relative "../scripts"
require_relative "hosting_parts"

module Hecks
  module Projections
    module Deploy
      module Box
        # The hosting scripts an AWS box deploy ships beside its stacks when the world sets
        # `hosting_scripts true`: the steps an operator runs once `make stacks` has created the box.
        # Container names, repositories, parameters and stacks come from the resolved plan, never
        # from this file.
        module Hosting
          extend HostingParts

          module_function

          # Adds the hosting scripts to a box file map when the world opts in.
          #
          # @param files [Hash{String => String}] the box target's own files, keyed by path
          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated AWS region
          # @return [Hash{String => String}] `files` itself without the opt-in, else a copy with
          #   `hosting.mk`, `deploy-service.sh`, `smoke-after-deploy.sh` and `expected-era`
          def extend_files(files, plan:, region:)
            return files unless plan.hosting

            files.merge(
              "hosting.mk"            => hosting_mk(plan),
              "deploy-service.sh"     => deploy_service_sh(plan, region),
              "smoke-after-deploy.sh" => smoke_after_deploy_sh(plan, region),
              "expected-era"          => Scripts.expected_era(plan.hosting)
            )
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the Makefile fragment the box `Makefile` includes
          def hosting_mk(plan)
            Box.template("hosting.mk.tmpl", "SERVICE"        => plan.containers.first.name,
                                            "URL"            => plan.hosting.public_url.to_s,
                                            "SMOKE_RECIPE"   => Box::SMOKE_RECIPE,
                                            "SERVICE_RECIPE" => service_recipe)
          end

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated AWS region
          # @return [String] `deploy-service.sh`
          def deploy_service_sh(plan, region)
            roll = plan.task_definition ? "deploy-service.taskdef-roll.part" : "deploy-service.services-roll.part"
            Box.template("deploy-service.sh.tmpl",
                         "STACK" => plan.infra_name, "MODE_SUMMARY" => mode_summary(plan),
                         "SETTINGS" => deploy_constants(plan, region), "SERVICES" => services_block(plan),
                         "REPOSITORY_STEP" => repository_step(plan),
                         "ROLL_STEPS" => part(roll))
          end

          # @return [String] the `deploy-service` recipe: the `service_roll.run` command
          def service_recipe
            args = "service=$(SERVICE) $(if $(EXISTING_TAG),existing_tag=$(EXISTING_TAG)) " \
                   "$(if $(LOCAL_IMAGE),local_image=$(LOCAL_IMAGE))"
            direct = "bash ./deploy-service.sh $(SERVICE)"
            Box::RollRecipe.call(command: "service_roll.run", args: args, direct: direct)
          end

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated AWS region
          # @return [String] `smoke-after-deploy.sh`
          def smoke_after_deploy_sh(plan, region)
            image_stack = plan.hosting.stack
            Box.template("smoke-after-deploy.sh.tmpl",
                         "STACK" => plan.infra_name, "SETTINGS" => smoke_constants(plan, region),
                         "SETTLE_CHECKS" => settle_checks(plan),
                         "IMAGE_STACK_WAIT" => image_stack ? ", stack #{image_stack}" : "")
          end
        end
      end
    end
  end
end
