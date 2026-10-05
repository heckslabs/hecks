require "shellwords"
require_relative "../scripts"

module Hecks
  module Projections
    module Deploy
      module Box
        # The hosting scripts an AWS box deploy ships beside its stacks when the world sets
        # `hosting_scripts true`: the steps an operator runs once `make stacks` has created the box.
        # Container names, repositories, parameters and stacks come from the resolved plan, never
        # from this file.
        module Hosting
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
            Box.template("hosting.mk.tmpl", "SERVICE" => plan.containers.first.name,
                                            "URL"     => plan.hosting.public_url.to_s)
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

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated AWS region
          # @return [String] `smoke-after-deploy.sh`
          def smoke_after_deploy_sh(plan, region)
            hosting = plan.hosting
            image_stack = hosting.stack
            Box.template("smoke-after-deploy.sh.tmpl",
                         "STACK" => plan.infra_name, "SETTINGS" => smoke_constants(plan, region),
                         "SETTLE_CHECKS" => settle_checks(plan),
                         "IMAGE_STACK_WAIT" => image_stack ? ", stack #{image_stack}" : "")
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the sentence that says what the roll puts on the box
          def mode_summary(plan)
            if plan.task_definition
              <<~TEXT.gsub(/^/, "# ").chomp
                It then sets the stack's matching image-tag parameter (UsePreviousValue for every other
                one, and it checks that only that one changed), reads the task definition the stack
                registers, refuses to roll it unless it carries the pushed image, and rolls it with
                deploy-box.sh.
              TEXT
            else
              <<~TEXT.gsub(/^/, "# ").chomp
                It then rolls the box with deploy-box.sh, naming the new tag for this container and the
                tag the box runs now for every other one.
              TEXT
            end
          end

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
            arms = plan.containers.map do |container|
              setting =
                if plan.task_definition
                  "CFN_PARAM_KEY=#{Shellwords.escape(container.tag_parameter)}"
                else
                  "ECR_REPOSITORY=#{Shellwords.escape(container.repository)}"
                end
              "    #{Shellwords.escape(container.name)}) #{setting} ;;"
            end
            <<~BASH.chomp
              SERVICES='#{plan.containers.map(&:name).join(' ')}'

              # Sets the container's settings for one service, or exits.
              resolve_service() {
                case "$1" in
              #{arms.join("\n")}
                  *) echo "unknown service '$1', must be one of: ${SERVICES}" >&2; exit 1 ;;
                esac
              }
            BASH
          end

          def repository_step(plan)
            plan.task_definition ? "#{part('deploy-service.taskdef.part')}\n\n" : ""
          end

          def part(file)
            file ? File.read(File.join(Box::TEMPLATE_DIR, file)).chomp : ""
          end

          private_class_method :deploy_constants, :smoke_constants, :smoke_defaults, :constants,
                               :services_block, :part, :repository_step, :settle_checks
        end
      end
    end
  end
end
