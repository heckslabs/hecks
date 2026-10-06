module Hecks
  module Projections
    module Deploy
      module Box
        # The files that roll the box and move a project onto it: `deploy-box.sh`, the Makefile and,
        # for a world that declares a `migration`, its copy scripts and runbook. Mixed into `Box`,
        # which supplies `template`.
        module RollScripts
          # The tooling that moves a project's data from its old database into the RDS instance, for
          # a world that declares a `migration`.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [Hash{String => String}] `restore-to-rds.sh`, `verify-copy.sh` and
          #   `MIGRATION.md`,
          #   or nothing
          def migration_files(plan)
            migration = plan.migration
            return {} unless migration

            values = { "STACK" => plan.infra_name, "SCHEMAS" => migration.schemas.join(" "),
                       "SCHEMAS_CSV" => migration.schemas.join(","), "DATABASE" => migration.database,
                       "SOURCE_DATABASE" => migration.source_database }
            {
              "restore-to-rds.sh" => template("restore-to-rds.sh.tmpl", values),
              "verify-copy.sh"    => template("verify-copy.sh.tmpl", values),
              "MIGRATION.md"      => migration_md(plan)
            }
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the runbook for moving onto the box, in the order the steps are run
          def migration_md(plan)
            migration = plan.migration
            template("MIGRATION.md.tmpl", "STACK" => plan.infra_name, "SCHEMA_LIST" => schema_list(migration),
                                          "SOURCE_DATABASE" => migration.source_database,
                                          "DATABASE" => migration.database, "RDS_STACK" => plan.rds_stack,
                                          "DEPLOY" => deploy_command(plan))
          end

          # @param plan [Settings::Plan] the resolved settings
          # @param region [String] the validated region
          # @return [String] `deploy-box.sh`
          def deploy_box_sh(plan, region)
            template("deploy-box.sh.tmpl", "STACK" => plan.infra_name, "BOX_STACK" => plan.box_stack,
                                           "RDS_STACK" => plan.rds_stack, "REGION" => region,
                                           "DIR" => "/opt/#{plan.infra_name}", "HEALTH_CHECKS" => health_checks(plan),
                                           "SMOKE_HEADER" => smoke_header(plan), "USAGE" => deploy_usage(plan),
                                           "DB_SECRET_LINE" => database_secret_line(plan))
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the line that adds the origin secret to the smoke listener's requests,
          #   or
          #   nothing when the world has no origin guard
          def smoke_header(plan)
            plan.origin_header ? "\t\theader_up #{plan.origin_header} {$ORIGIN_SECRET}" : ""
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the comment lines that say how to call `deploy-box.sh`
          def deploy_usage(plan)
            return template("deploy-usage-services.tmpl", {}) unless plan.task_definition

            template("deploy-usage-taskdef.tmpl", "TASK_DEFINITION" => plan.task_definition)
          end

          # The probes the post-roll check runs on the box, against the proxy on localhost.
          #
          # @param plan [Settings::Plan] the resolved settings
          # @return [String] bash lines that set `BAD=1` on a failed probe
          def health_checks(plan)
            probes =
              if plan.origin_header
                guarded_probes(plan.origin_header)
              else
                [health_probe("the proxy serves /", "", '[ "${code#5}" = "$code" ]')]
              end
            (probes + tunnel_probe(plan)).join("\n")
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [Array<String>] the probe that waits for the tunnel to register, when one runs
          def tunnel_probe(plan)
            return [] unless plan.tunnel_service

            [<<~SH.chomp]
              for _ in 1 2 3 4 5 6; do
                n=$(docker compose -f compose.json logs --no-color cloudflared 2>&1 | grep -ci "registered tunnel connection" || true)
                [ "$n" -gt 0 ] && break
                sleep 5
              done
              [ "$n" -gt 0 ] && echo "ok   the tunnel registered $n connections" || { echo "FAIL the tunnel has no connection"; BAD=1; }
            SH
          end

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] a Makefile whose targets create the two stacks and roll the box
          def makefile(plan)
            hint = plan.task_definition ? "[TASKDEF=family:revision]" : '[TAGS="web=20260101 worker=20260101"]'
            base = template("Makefile.tmpl", { "STACK" => plan.infra_name, "DEPLOY_HINT" => hint,
                                               "RDS_STACK" => plan.rds_stack, "BOX_STACK" => plan.box_stack,
                                               "DEPLOY_RECIPE" => RollRecipe.deploy(plan) }
                                               .merge(database_makefile_values(plan)))
            plan.hosting ? "#{base}\ninclude hosting.mk\n" : base
          end

          private

          def schema_list(migration)
            migration.schemas.map { |name| "`#{name}`" }.join(", ")
          end

          def deploy_command(plan)
            plan.task_definition ? "make deploy TASKDEF=#{plan.task_definition}:<revision>" : "make deploy"
          end

          def guarded_probes(header)
            [
              "S=$(grep ^ORIGIN_SECRET= caddy.secrets.env | cut -d= -f2-)",
              health_probe("a request without the origin secret is refused", "", '[ "$code" = 403 ]'),
              health_probe("a request with the origin secret is served", %( -H "#{header}: $S"),
                           '[ "${code#5}" = "$code" ]')
            ]
          end

          def health_probe(label, args, wanted)
            write_out = '-w "%{http_code}"' # rubocop:disable Style/FormatStringToken -- curl's own token
            <<~SH.chomp
              code=$(curl -s -o /dev/null #{write_out} --max-time 40 localhost/#{args})
              #{wanted} && echo "ok   #{label} -> $code" || { echo "FAIL #{label} -> $code"; BAD=1; }
            SH
          end
        end
      end
    end
  end
end
