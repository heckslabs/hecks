# frozen_string_literal: true

require_relative "statuses"

module Hecks
  module Adapters
    class DeployToolchain
      # The answers the asks hand on to the policies that follow them: plans, confirmations, what a
      # roll or a data copy carries, and the bluebook comparison.
      module Answers
        include Statuses

        private

        # Runs the confirmed restore and answers what it printed.
        def restore(held)
          script = Scripts::Script.new(RESTORE_SCRIPT, "restore", RESTORE_STATUS, copy_args(held))
          copy_answer(held, run_script(script, held, copy_env(held))[:report][:value], planned: false)
        end

        # What a preview verb that writes would do, read from the script, or nil for one that reads.
        # A dry run answers the plan; otherwise the write needs `confirm`.
        #
        # @return [Hash, nil] the dry run's answer, when it is one
        def gate_preview(held, action)
          return unless PREVIEW_WRITES.include?(action)

          script = script_for(PREVIEW_SCRIPT, plain(held[:project]), plain(held[:script]))
          plan = DeployPlans.preview(File.read(script), action, plain(held[:branch]))
          return planned_answer("#{action}: #{plan}") if plain(held[:dry_run]) == true

          require_confirm(held, "#{action} a preview", plan)
          nil
        end

        # What rolling the companion would do, read from its script.
        def companion_plan(held, name, companion)
          script = script_for(name, plain(held[:project]), plain(held[:script]))
          DeployPlans.companion(File.read(script), companion, plain(held[:taskdef]))
        end

        # A dry run's answer: the plan, and nothing run.
        def planned_answer(plan)
          { outcome: { value: "planned" }, report: { value: "#{plan}\ndry run: nothing was run" }, planned: { value: true } }
        end

        def require_confirm(held, what, plan)
          return if plain(held[:confirm]) == true

          raise ConsoleCapture::Failure,
                "refusing to #{what}: #{plan}\npass confirm=true to run it (dry_run=true prints this plan)"
        end

        def diff_files(old, new)
          report = BluebookReport.new(File.read(File.expand_path(old)), File.read(File.expand_path(new)))
          diff_answer(report.changed? ? "changed" : "unchanged", report.text)
        rescue SystemCallError, JSON::ParserError, TypeError, KeyError => e
          diff_answer("unavailable", "bluebooks: could not compare #{old} and #{new} (#{e.message.lines.first.strip})")
        end

        # The script reads the registry and the local image; its report says what it found.
        def diff_script(held)
          text = run_script(Scripts::Script.new(DIFF_SCRIPT, "bluebook diff", {}), held, {}).dig(:report, :value)
          return diff_answer("unavailable", text) if text.match?(DIFF_UNAVAILABLE)

          diff_answer(text.include?("no bluebook changes.") ? "unchanged" : "changed", text)
        rescue ConsoleCapture::Failure => e
          diff_answer("unavailable", "bluebooks: #{e.message.lines.first.strip}; nothing to compare.")
        end

        def diff_answer(outcome, text) = { outcome: { value: outcome }, report: { value: text } }

        # What a data copy's answer hands on to the policies that follow it.
        def copy_answer(held, report, planned:)
          carried = %i[project bastion source source_secret target target_secret source_db target_db]
                    .to_h { |key| [key, { value: plain(held[key]).to_s }] }
          verify = !planned && plain(held[:skip_verify]) != true
          carried.merge(report: { value: report }, planned: { value: planned }, run_verify: { value: verify })
        end

        # A database name the record gave, or nil when it left the script's default.
        def database(argument) = plain(argument).to_s.empty? ? nil : plain(argument)

        def copy_args(held) = %i[bastion source source_secret target target_secret].map { |key| plain(held[key]) }

        def copy_env(held)
          { "FORCE" => flag(held[:force]), "SRC_DB" => database(held[:source_db]), "DST_DB" => database(held[:target_db]),
            "VERIFY_BY_COMMAND" => "1" }.compact
        end

        # What the script would overwrite, read from the script itself (its schemas and databases).
        # Its schemas are the default of the `SCHEMAS=${SCHEMAS:-"..."}` line (overridable).
        def copy_plan(script, held)
          text = File.read(script)
          schemas = text[/^SCHEMAS=(?:\$\{SCHEMAS:-)?"([^"]*)"/, 1].to_s.split.join(", ")
          source_db, target_db = copy_databases(text, held)
          drop = plain(held[:force]) == true ? "; force=true drops each target schema first" : ""
          "copy schemas #{schemas} from database #{source_db} on #{plain(held[:source])} into database " \
            "#{target_db} on #{plain(held[:target])} through bastion #{plain(held[:bastion])}, " \
            "OVERWRITING those schemas there#{drop}"
        end

        # The source and target databases: the record's, else the script's defaults.
        def copy_databases(text, held)
          databases = text.match(/^SRC_DB=\$\{SRC_DB:-([^}]*)\}; DST_DB=\$\{DST_DB:-([^}]*)\}/)
          [database(held[:source_db]) || databases&.[](1), database(held[:target_db]) || databases&.[](2)]
        end

        # What a roll's answer hands on to the policies that follow it: the project to find the
        # smoke in, whether to request the smoke (not when the record opted out or the project has
        # no smoke script, either of which is noted on the record), and which roll asked.
        def carried(held, kind)
          skipped = plain(held[:skip_smoke]) == true
          script = smoke_script?(plain(held[:project]))
          note = "smoke skipped: skip_smoke=true" if skipped
          note ||= "smoke skipped: no smoke script" unless script
          { project: { value: plain(held[:project]) }, skip_smoke: { value: skipped },
            run_smoke: { value: note.nil? }, smoke: wrapped(note), kind: { value: kind } }
        end

        # Whether the project has a generated smoke script the smoke could run.
        def smoke_script?(project)
          script_for(SMOKE_SCRIPT, project, nil)
          true
        rescue ConsoleCapture::Failure
          false
        end

        def wrapped(text) = text.to_s.empty? ? nil : { value: text }

        # What `deploy-box.sh` takes: a task definition, or `name=tag` words.
        def box_args(held) = [plain(held[:taskdef]), *plain(held[:tags]).to_s.split].compact

        # The taskdef and tag a service roll's last line names.
        def rolled(text)
          match = text.match(/^==> rolled taskdef=(\S*) tag=(\S+)$/)
          { taskdef: wrapped(match&.[](1)), tag: wrapped(match&.[](2)) }
        end
      end
    end
  end
end
