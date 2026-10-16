module Hecks
  module Projections
    module Deploy
      module Box
        # Where the box's containers write their logs. With `logs "cloudwatch"` (the default) every
        # service uses Docker's `awslogs` driver into one log group the box stack creates, one
        # stream per service, and the box role may write to that group only. With `logs "local"`
        # the services keep Docker's rotating `json-file` logs, which a roll deletes with the
        # container.
        #
        # `docker logs` keeps working with `awslogs`: Docker's dual-logging cache (Docker 20.10 and
        # later, which the Amazon Linux 2023 package installs) keeps a local copy for reads.
        # Mixed into `Box`, which supplies `template`.
        module Logging
          LOG_EXIT_CODE = "#   44  the box stack has no log group yet: update the stack (make stacks) before rolling\n".freeze
          LOG_NOTE = <<~NOTE.freeze
            # Every container logs to the CloudWatch group the box stack creates. A container whose log
            # stream cannot be written does not start, so the roll first checks that the stack has the
            # group (and the role's right to write it) and exits 44 if not. SKIP_LOG_GROUP_CHECK=1 skips it.
            # `docker logs` and the log capture below still read the box's local copy (Docker's dual-logging cache).
            #
          NOTE
          LOG_GROUP_CHECK = <<~CHECK.freeze
            if [ "${SKIP_LOG_GROUP_CHECK:-}" = 1 ]; then
              echo "==> skipping the log group check (SKIP_LOG_GROUP_CHECK=1)"
            elif ! aws cloudformation describe-stack-resource --stack-name "$BOX_STACK" --logical-resource-id BoxLogGroup >/dev/null 2>&1; then
              echo "==> $BOX_STACK has no BoxLogGroup: its containers would fail to start on the awslogs driver." >&2
              echo "    Run make stacks to update box.yaml (log group and the role's logs policy) first, then roll again." >&2
              exit 44
            fi
          CHECK
          COMPOSE_LOG_NOTE = <<~NOTE.freeze
            #
            # Every service logs to the CloudWatch group the box stack creates (one stream per service). A
            # container whose stream cannot be written does not start, so update the box stack (make stacks:
            # the group and the role's logs policy) before the first roll that uses this file. `docker logs`
            # still reads the box's local copy.
          NOTE
          JSON_FILE = '{driver: "json-file", options: {"max-size": "10m", "max-file": "3"}}'.freeze

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the log group resource spliced into `box.yaml`, or nothing for `local`
          def log_group_yaml(plan)
            return "" unless plan.cloudwatch_logs?

            template("log-group.yaml.tmpl", "LOG_GROUP"      => plan.log_group,
                                            "RETENTION_DAYS" => plan.log_retention_days.to_s)
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the role policy that lets the box write to its log group only, or
          #   nothing for `local`
          def log_policy_yaml(plan)
            plan.cloudwatch_logs? ? template("log-policy.yaml.tmpl", {}) : ""
          end

          # The values `render-compose.sh` splices in: the jq definition of `log` and the call that
          # names each service's stream. `local` renders the `json-file` definition and the bare
          # `log`, so its output does not change.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @param service [String] the jq expression for a service's name in the template
          # @return [Hash{String => String}] the template values
          def compose_log_values(plan, region, service)
            return { "COMPOSE_LOG_NOTE" => "", **local_log_values } unless plan.cloudwatch_logs?

            { "COMPOSE_LOG_NOTE" => COMPOSE_LOG_NOTE, "LOG_DEF" => awslogs_definition(plan, region),
              "LOG_SERVICE" => "log(#{service})", "LOG_CADDY" => 'log("caddy")', "LOG_TUNNEL" => 'log("cloudflared")' }
          end

          # The `deploy-box.sh` pieces that stop a roll onto a stack without the log group.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [Hash{String => String}] the exit-code line, the comment and the check, or empty
          #   strings for `local`
          def log_roll_values(plan)
            return { "LOG_EXIT_CODE" => "", "LOG_NOTE" => "", "LOG_GROUP_CHECK" => "" } unless plan.cloudwatch_logs?

            { "LOG_EXIT_CODE" => LOG_EXIT_CODE, "LOG_NOTE" => LOG_NOTE, "LOG_GROUP_CHECK" => LOG_GROUP_CHECK }
          end

          private

          def awslogs_definition(plan, region)
            options = %({"awslogs-region": "#{region}", "awslogs-group": "#{plan.log_group}", \
"awslogs-create-group": "false", tag: $service})
            %(def log($service): {driver: "awslogs", options: #{options}};)
          end

          def local_log_values
            { "LOG_DEF" => "def log: #{JSON_FILE};", "LOG_SERVICE" => "log", "LOG_CADDY" => "log",
              "LOG_TUNNEL" => "log" }
          end
        end
      end
    end
  end
end
