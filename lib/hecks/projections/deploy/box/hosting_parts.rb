require "shellwords"

module Hecks
  module Projections
    module Deploy
      module Box
        # The pieces `Hosting` splices into its scripts: the settings each script starts with, the
        # service case arms and the sentences that say what a roll does. Extended onto `Hosting`.
        module HostingParts
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the sentence that says what the roll puts on the box
          def mode_summary(plan)
            file = plan.task_definition ? "mode-summary-taskdef.tmpl" : "mode-summary-services.tmpl"
            Box.template(file, {}).gsub(/^/, "# ").chomp
          end

          private

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the comment lines that list what "settled" means
          def settle_checks(plan)
            stacks = plan.hosting.stack ? "the box stack and the #{plan.hosting.stack} stack are" : "the box stack is"
            checks = ["#{stacks} CREATE_COMPLETE or UPDATE_COMPLETE, never rolled back or failed;",
                      "every container and the proxy of the box's Compose project is up and has stayed up;"]
            if plan.task_definition
              checks << "each container runs the image of the task definition it was rolled from (the latest " \
                        "#{plan.task_definition} unless TASKDEF says otherwise)."
            end
            checks.map { |line| "#      - #{line}" }.join("\n")
          end

          def deploy_constants(plan, region)
            lines = { "REGION" => region }
            if plan.task_definition
              lines["FAMILY"] = plan.task_definition
              lines["IMAGE_STACK"] = plan.hosting.stack
            else
              lines["BOX_STACK"] = plan.box_stack
              lines["BOX_DIR"] = "/opt/#{plan.infra_name}"
            end
            constants(lines)
          end

          def smoke_constants(plan, region)
            hosting = plan.hosting
            watched = [plan.box_stack, hosting.stack].compact
            constants(
              "REGION" => region, "BOX_STACK" => plan.box_stack, "BOX_DIR" => "/opt/#{plan.infra_name}",
              "WATCHED_STACKS" => watched.join(" "),
              "EXPECTED_SERVICES" => (plan.containers.map(&:name) + ["caddy"]).join(" ")
            ).concat("\n#{smoke_defaults(plan)}")
          end

          def smoke_defaults(plan)
            hosting = plan.hosting
            [
              "TASK_DEFINITION=\"${TASKDEF:-#{plan.task_definition}}\"",
              "REPO=\"${REPO:-#{hosting.smoke_repo}}\"",
              "WORKFLOW=\"${WORKFLOW:-#{hosting.smoke_workflow}}\"",
              "SMOKE_REF=\"${SMOKE_REF:-#{hosting.smoke_ref}}\""
            ].join("\n")
          end

          def constants(values)
            values.map { |name, value| "#{name}=#{Shellwords.escape(value)}" }.join("\n")
          end

          # One case arm per container that sets the repository and image-tag parameter to use, and
          # the list of names the script accepts.
          def services_block(plan)
            arms = plan.containers.map { |container| service_arm(plan, container) }
            Box.template("services-block.tmpl", "NAMES" => plan.containers.map(&:name).join(" "),
                                                "ARMS"  => arms.join("\n")).chomp
          end

          def service_arm(plan, container)
            setting =
              if plan.task_definition
                "CFN_PARAM_KEY=#{Shellwords.escape(container.tag_parameter)}"
              else
                "ECR_REPOSITORY=#{Shellwords.escape(container.repository)}"
              end
            "    #{Shellwords.escape(container.name)}) #{setting} ;;"
          end

          def repository_step(plan)
            plan.task_definition ? "#{part("deploy-service.taskdef.part")}\n\n" : ""
          end

          def part(file)
            file ? File.read(File.join(Box::TEMPLATE_DIR, file)).chomp : ""
          end
        end
      end
    end
  end
end
