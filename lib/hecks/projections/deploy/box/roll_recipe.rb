module Hecks
  module Projections
    module Deploy
      module Box
        # The Makefile recipes that run a roll as `box_roll.run` or `service_roll.run`.
        #
        # The command rolls with the generated script and, through its policy, requests the
        # smoke, so one deploy leaves a `BoxRoll` or `ServiceRoll` (which also records the smoke's
        # outcome) and a `SmokeRun` in the Hecks database. A failed roll or smoke is the command's
        # exit 1, with the script's status in its message. With no database the command never
        # starts, so the recipe runs the script itself, states the database error apart from the
        # deploy's result, and fails (`Error 24` if all passed).
        module RollRecipe
          module_function

          # @param plan [Settings::Plan] the resolved settings
          # @return [String] the `deploy` target's recipe, tab-indented: the `box_roll.run` command
          def deploy(plan)
            variable = plan.task_definition ? "TASKDEF" : "TAGS"
            args = plan.task_definition ? "$(if $(TASKDEF),taskdef=$(TASKDEF))" : "$(if $(TAGS),tags=\"$(TAGS)\")"
            direct = "bash ./deploy-box.sh $(#{variable})"
            direct += " || exit $$?; TASKDEF=\"$(TASKDEF)\" bash ./smoke-after-deploy.sh" if plan.hosting
            "\t#{call(command: 'box_roll.run', args: args, direct: direct)}"
          end

          # @param command [String] the Deploy command, such as `box_roll.run`
          # @param args [String] the Makefile text that turns variables into the arguments
          # @param direct [String] the shell that runs the script when there is no database
          # @return [String] the recipe lines, joined for a Makefile rule
          def call(command:, args:, direct:)
            [*run_lines(command, args), *no_database_lines(direct), *outcome_lines].join("\n\t").freeze
          end

          def run_lines(command, args)
            ["@err=$$(mktemp); run=deploy-$$(date -u +%Y%m%d%H%M%S); \\",
             "$(HECKS) deploy #{command} project=\"$(CURDIR)\" run=\"$$run\" #{args} \\",
             '  $(if $(SKIP_POST_DEPLOY_SMOKE),skip_smoke=true) --wait 2>"$$err"; rc=$$?; \\']
          end

          def no_database_lines(direct)
            ['if [ $$rc -ne 0 ] && grep -q \'^cannot open Hecks\' "$$err"; then \\',
             '  echo "==> the deploy record was NOT written: $$(grep -m1 \'^cannot open Hecks\' "$$err")" >&2; \\',
             '  echo "    one-time setup on this machine: createdb hecks, or set HECKS_DATABASE to a Postgres URL" >&2; \\',
             '  echo "    deploying anyway so the deploy is not lost" >&2; \\',
             "  rm -f \"$$err\"; #{direct}; rc=$$?; \\",
             '  echo "==> deploy exit $$rc. The deploy record was NOT written: the database is unavailable (see above)." >&2; \\',
             "  [ $$rc -ne 0 ] || rc=24; exit $$rc; \\",
             "fi; \\"]
          end

          def outcome_lines
            ['cat "$$err" >&2; rm -f "$$err"; exit $$rc']
          end

          private_class_method :run_lines, :no_database_lines, :outcome_lines
        end
      end
    end
  end
end
