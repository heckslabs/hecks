# frozen_string_literal: true

require_relative "console_capture"
require_relative "shell"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"
require "hecks/projections/deploy/template_diff"
require_relative "bluebook_report"
require_relative "deploy_plans"

module Hecks
  module Adapters
    # The `DeployToolchain` port's adapter: generates a domain's deploy recipe, lints and compares
    # what was generated, and projects the OIDC manifests.
    #
    # The recipe, the lint and the manifests run the `Hecks::Tools` tool that already does the work,
    # in this process with its printing and exit status captured: a tool that ends non-zero is a
    # refusal whose reason is what it printed. The lint and the manifests write into a hecks
    # checkout, so outside one the ask is refused with "needs a hecks checkout". The recipe reads
    # the project it is given, wherever that is, so it needs no checkout, and neither does a
    # comparison.
    class DeployToolchain
      # The `Hecks::Tools` tool an ask runs, by ask.
      SCRIPTS = { generate: "project_deploy", lint: "lint_deploy_recipes", manifest: "project_oidc" }.freeze

      # `hecks deploy recipe.project`'s flag for each `Recipe` field it takes.
      GENERATE_FLAGS = { "--tenant" => :tenant, "--schema" => :schema, "--out" => :out,
                         "--environment" => :environment }.freeze

      # The file name the AwsBox projection gives the post-deploy smoke.
      SMOKE_SCRIPT = "smoke-after-deploy.sh"

      # What each status of `smoke-after-deploy.sh` means, for the reason a refusal gives.
      SMOKE_STATUS = { 20 => "the roll did not settle", 21 => "gh missing or no repository, smoke not run",
                       22 => "the smoke failed", 23 => "the smoke's result is unknown" }.freeze

      # The file names the AwsBox projection gives the two rolls.
      SERVICE_SCRIPT = "deploy-service.sh"
      BOX_SCRIPT = "deploy-box.sh"

      # What each status of `deploy-box.sh` means, for the reason a refusal gives.
      BOX_STATUS = { 40 => "the box stack has no instance", 41 => "the roll did not succeed on the box",
                     42 => "the box is not healthy after the roll" }.freeze

      # What each status of `deploy-service.sh` means; it ends with the box roll's own statuses.
      SERVICE_STATUS = { 2 => "unknown service", 30 => "the existing tag is not in ECR",
                         31 => "the fresh tag is already in ECR", 32 => "the box's Compose file is unreadable",
                         33 => "the box stack has no instance", 34 => "the stack has no parameter for the container",
                         35 => "the stack update failed or did not settle",
                         36 => "a parameter other than the container's changed",
                         37 => "the task definition lacks the pushed image",
                         38 => "the task definition has no such container" }.merge(BOX_STATUS).freeze

      # The file names the AwsBox projection gives the data copy and its comparison.
      RESTORE_SCRIPT = "restore-to-rds.sh"
      VERIFY_SCRIPT = "verify-copy.sh"

      # The status `verify-copy.sh` ends with when the databases differ: an answer, not a refusal.
      DRIFT_STATUS = 50

      # What each status of `restore-to-rds.sh` means, for the reason a refusal gives.
      RESTORE_STATUS = { 60           => "a Postgres client older than 16",
                         61           => "the target already has a schema; force=true replaces it",
                         62           => "unexpected errors restoring a schema",
                         DRIFT_STATUS => "the copy does not match the source" }.freeze

      # The file name of the bluebook report script and of the preview script; a companion roll runs
      # `deploy-<companion>.sh`.
      DIFF_SCRIPT = "bluebooks-diff.sh"
      PREVIEW_SCRIPT = "preview.sh"

      # What `preview.sh` ends with: every refusal and failure is 1, a bad verb 2.
      PREVIEW_STATUS = { 1 => "the preview script refused or failed", 2 => "usage" }.freeze

      # What a roll script ends with: every refusal and failed check is 1.
      COMPANION_STATUS = { 1 => "the roll was refused, did not succeed, or the companion is not healthy" }.freeze

      # The outcome each `preview.sh` verb records; the writes among them need `confirm`.
      PREVIEW_OUTCOMES = { "name" => "named", "url" => "located", "list" => "listed", "deploy" => "deployed",
                           "destroy" => "destroyed", "login" => "signed_in" }.freeze
      PREVIEW_WRITES = %w[deploy destroy login].freeze

      # What `bluebooks-diff.sh` prints when it has nothing to compare.
      DIFF_UNAVAILABLE = /^==> bluebooks: (could not read|the local domain image has no|the running domain image .* predates)/

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a domain's deploy recipe from its declared `deployed_to` target, through
      # `hecks deploy recipe.project`.
      #
      # The domain and `out` are paths relative to where the command runs, or absolute, so a
      # project outside the hecks checkout (an installed gem has none) works. The Makefiles name
      # the checkout as their root when the tree is one, else the directory the command runs in.
      #
      # @param held [Hash] the `Recipe` record: `domain`, and `tenant`, `schema`, `out` and
      #   `environment` when set
      # @return [Hash{Symbol => Hash}] `output:` one line per file written
      # @raise [ConsoleCapture::Failure] when the generator refuses (no `deployed_to` target,
      #   conflicting settings, a schema with no tenant)
      def generate(**held)
        tree = Codebase::Tree.new
        root = tree.checkout? ? tree.root : Dir.pwd
        flags = GENERATE_FLAGS.filter_map do |flag, key|
          value = plain(held[key])
          next if value.nil?

          "#{flag}=#{key == :out ? File.expand_path(value) : value}"
        end
        domain = project_path(plain(held[:domain]), root)
        run(Codebase::Tree.new(root: root), :generate, [*flags, domain])
      end

      # Lints generated deploy Makefiles for prod-touching recipes that hide failure, through
      # `hecks deploy makefile_check.lint`.
      #
      # @param held [Hash] the `MakefileCheck` record: `makefiles` (comma separated paths; three
      #   generated fixture domains when absent)
      # @return [Hash{Symbol => Hash}] `report:` what the linter printed
      # @raise [ConsoleCapture::Failure] when the tree is not a checkout, or the linter found a
      #   violation; the message is its report
      def scan(**held)
        paths = plain(held[:makefiles]).to_s.split(",").map(&:strip).reject(&:empty?)
        { report: { value: child(:lint, paths).dig(:output, :value) } }
      end

      # Projects each domain's OIDC client and scope manifest into its `oidc.json`, through
      # `hecks deploy oidc_manifest.project_oidc`.
      #
      # @param held [Hash] the `OidcManifest` record: `domains` (comma separated directories; every
      #   domain of the checkout when absent)
      # @return [Hash{Symbol => Hash}] `output:` one line per manifest written or skipped
      # @raise [ConsoleCapture::Failure] when the tree is not a checkout
      def manifest(**held)
        domains = plain(held[:domains]).to_s.split(",").map(&:strip).reject(&:empty?)
        child(:manifest, domains)
      end

      # Compares two CloudFormation templates by logical id, in this process.
      #
      # A difference is an answer, not a refusal: `different:` says whether there was one, and
      # the record decides what a difference means.
      #
      # @param held [Hash] the `TemplateComparison` record: `before`, `after`, and `json` and
      #   `strict` when set
      # @return [Hash{Symbol => Hash}] `report:` the comparison as text (JSON when `json`), and
      #   `different:` whether the templates differ
      # @raise [ConsoleCapture::Failure] when a template is missing or is not a template
      def compare(**held)
        diff = Projections::Deploy::TemplateDiff
        report = diff.diff_files(plain(held[:before]), plain(held[:after]), strict: plain(held[:strict]) == true)
        text = plain(held[:json]) == true ? diff.render_json(report) : diff.render(report)
        { report: { value: text }, different: { value: report.different? } }
      rescue ArgumentError => e
        raise ConsoleCapture::Failure, e.message
      end

      # Runs a project's generated `smoke-after-deploy.sh`, through `hecks deploy smoke_run.run`.
      #
      # The script is the one the AwsBox projection writes, found beside the Makefile or, failing
      # that, the only one under the project (`script` names it otherwise). It waits for the roll
      # to settle, then dispatches and follows the smoke workflow, and only ever reads AWS. Its
      # options travel in the environment variables it documents.
      #
      # @param held [Hash] the `SmokeRun` record: `project`, and `script`, `taskdef`, `skip`,
      #   `async` and `dry_run` when set
      # @return [Hash{Symbol => Hash}] `report:` what the script printed
      # @raise [ConsoleCapture::Failure] when no script, or more than one, is found, or it ends
      #   non-zero; the message names its status and what it printed
      def smoke(**held)
        run_script(SMOKE_SCRIPT, held, smoke_env(held), "smoke", SMOKE_STATUS)
      end

      # Rolls one service with a project's generated `deploy-service.sh`, through
      # `hecks deploy service_roll.run`.
      #
      # The script pushes the image under a fresh tag, sets the stack's tag parameter and rolls
      # the box, so it writes to AWS (a spec puts stand-in programs first on `PATH`).
      # `SMOKE_BY_COMMAND=1` leaves the smoke to the record's policy; the task definition and
      # tag come from the script's last line.
      #
      # @param held [Hash] the `ServiceRoll` record: `project`, `service`, and `script`,
      #   `existing_tag` and `local_image` when set
      # @return [Hash{Symbol => Hash}] `report:`, and `taskdef:` and `tag:` when named
      # @raise [ConsoleCapture::Failure] when no script is found or it ends non-zero
      def roll_service(**held)
        env = { "EXISTING_TAG" => plain(held[:existing_tag]), "LOCAL_IMAGE" => plain(held[:local_image]),
                "SMOKE_BY_COMMAND" => "1" }.compact
        answer = run_script(SERVICE_SCRIPT, held, env, "service roll", SERVICE_STATUS, args: [plain(held[:service])])
        match = answer[:report][:value].match(/^==> rolled taskdef=(\S*) tag=(\S+)$/)
        answer.merge(taskdef: wrapped(match&.[](1)), tag: wrapped(match&.[](2))).merge(carried(held, "service_roll"))
      end

      # Rolls the whole box with a project's generated `deploy-box.sh`, through
      # `hecks deploy box_roll.run`.
      #
      # @param held [Hash] the `BoxRoll` record: `project`, and `script`, `taskdef`, `tags` when set
      # @return [Hash{Symbol => Hash}] `report:` what the script printed
      # @raise [ConsoleCapture::Failure] when no script, or more than one, is found, or it ends
      #   non-zero; the message names its status and what it printed
      def roll_box(**held)
        answer = run_script(BOX_SCRIPT, held, {}, "box roll", BOX_STATUS, args: box_args(held))
        answer.merge(carried(held, "box_roll")).merge(taskdef: wrapped(plain(held[:taskdef])))
      end

      # Copies a project's schemas into RDS with its generated `restore-to-rds.sh`, through
      # `hecks deploy data_copy.restore`.
      #
      # The script overwrites the target database's schemas, so the adapter refuses unless the
      # record says `confirm`, naming what would be overwritten. A `dry_run` answers the plan and
      # runs nothing (confirmed or not). The script runs with `VERIFY_BY_COMMAND=1`: the record's
      # policy requests the comparison, unless `skip_verify` or a dry run.
      #
      # @param held [Hash] the `DataCopy` record
      # @return [Hash{Symbol => Hash}] `report:`, `planned:` and what the policies carry on
      # @raise [ConsoleCapture::Failure] when no script is found, the copy is not confirmed, or the
      #   script ends non-zero
      def copy_data(**held)
        script = script_for(RESTORE_SCRIPT, plain(held[:project]), plain(held[:script]))
        plan = copy_plan(script, held)
        return copy_answer(held, "#{plan}\ndry run: nothing was run", planned: true) if plain(held[:dry_run]) == true

        unless plain(held[:confirm]) == true
          raise ConsoleCapture::Failure,
                "refusing to restore: #{plan}\npass confirm=true to run it (dry_run=true prints this plan)"
        end

        answer = run_script(RESTORE_SCRIPT, held, copy_env(held), "restore", RESTORE_STATUS, args: copy_args(held))
        copy_answer(held, answer[:report][:value], planned: false)
      end

      # Compares two databases with a project's generated `verify-copy.sh`, through
      # `hecks deploy data_copy.verify`. Read-only on both. Differing databases are an answer
      # (`drifted:`), not a refusal.
      #
      # @param held [Hash] the `CopyVerification` record
      # @return [Hash{Symbol => Hash}] `report:` and `drifted:`
      # @raise [ConsoleCapture::Failure] when no script is found or it fails for another reason
      def compare_copy(**held)
        env = { "A_DB" => database(held[:source_db]), "B_DB" => database(held[:target_db]) }.compact
        answer = run_script(VERIFY_SCRIPT, held, env, "verify", {}, args: copy_args(held), answering: [DRIFT_STATUS])
        { report: answer[:report], drifted: { value: answer.key?(:status) } }
      end

      # Reports which bluebook releases a deploy changes, through `hecks deploy bluebook_diff.run`.
      #
      # With `old` and `new` (two `package.verify` outputs) the comparison is made here, offline.
      # With neither, the project's `bluebooks-diff.sh` reads the running image's bluebooks
      # (read-only) and its report is classified. Never a failure: what cannot be compared is
      # `unavailable`. Only one of `old` and `new` is refused.
      #
      # @param held [Hash] the `BluebookDiff` record
      # @return [Hash{Symbol => Hash}] `outcome:` (unchanged, changed or unavailable) and `report:`
      # @raise [ConsoleCapture::Failure] when only one of `old` and `new` is given
      def compare_bluebooks(**held)
        old = plain(held[:old])
        new = plain(held[:new])
        raise ConsoleCapture::Failure, "give old= and new= together, or neither" if old.nil? != new.nil?

        old ? diff_files(old, new) : diff_script(held)
      end

      # Runs a project's `preview.sh` with one verb, through `hecks deploy preview_run.<verb>`.
      #
      # `name`, `url` and `list` read. `deploy`, `destroy` and `login` write to AWS or read its
      # secrets, so they refuse unless the record says `confirm`, naming the plan; `dry_run` answers
      # that plan and runs nothing. The branch travels in `BRANCH`, as the script reads it.
      #
      # @param held [Hash] the `PreviewRun` record
      # @return [Hash{Symbol => Hash}] `outcome:`, `report:` and `planned:`
      # @raise [ConsoleCapture::Failure] when no script is found, a write is not confirmed, or the
      #   script ends non-zero
      def run_preview(**held)
        action = plain(held[:action]).to_s
        script = script_for(PREVIEW_SCRIPT, plain(held[:project]), plain(held[:script]))
        if PREVIEW_WRITES.include?(action)
          plan = DeployPlans.preview(File.read(script), action, plain(held[:branch]))
          return planned_answer("#{action}: #{plan}") if plain(held[:dry_run]) == true

          require_confirm(held, "#{action} a preview", plan)
        end
        env = { "BRANCH" => plain(held[:branch]) }.compact
        answer = run_script(PREVIEW_SCRIPT, held, env, "preview #{action}", PREVIEW_STATUS, args: [action])
        { outcome: { value: PREVIEW_OUTCOMES.fetch(action) }, report: answer[:report], planned: { value: false } }
      end

      # Rolls a companion Compose project onto the box with a project's `deploy-<companion>.sh`,
      # through `hecks deploy companion_roll.run`.
      #
      # The script sends the project and its secret references to the box over SSM and starts it, so
      # the adapter refuses unless the record says `confirm`, naming the plan; `dry_run` answers the
      # plan and runs nothing. The task definition is the script's one argument.
      #
      # @param held [Hash] the `CompanionRoll` record
      # @return [Hash{Symbol => Hash}] `report:` and `planned:`
      # @raise [ConsoleCapture::Failure] when no script is found, the roll is not confirmed, or the
      #   script ends non-zero
      def roll_companion(**held)
        companion = plain(held[:companion]).to_s
        name = "deploy-#{companion}.sh"
        script = script_for(name, plain(held[:project]), plain(held[:script]))
        plan = DeployPlans.companion(File.read(script), companion, plain(held[:taskdef]))
        return planned_answer(plan) if plain(held[:dry_run]) == true

        require_confirm(held, "roll #{companion}", plan)
        answer = run_script(name, held, {}, "companion roll", COMPANION_STATUS, args: [plain(held[:taskdef])])
        answer.merge(planned: { value: false })
      end

      private

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
        text = run_script(DIFF_SCRIPT, held, {}, "bluebook diff", {}).dig(:report, :value)
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
      def copy_plan(script, held)
        text = File.read(script)
        schemas = text[/^SCHEMAS="([^"]*)"/, 1].to_s.split.join(", ")
        databases = text.match(/^SRC_DB=\$\{SRC_DB:-([^}]*)\}; DST_DB=\$\{DST_DB:-([^}]*)\}/)
        source_db = database(held[:source_db]) || databases&.[](1)
        target_db = database(held[:target_db]) || databases&.[](2)
        drop = plain(held[:force]) == true ? "; force=true drops each target schema first" : ""
        "copy schemas #{schemas} from database #{source_db} on #{plain(held[:source])} into database " \
          "#{target_db} on #{plain(held[:target])} through bastion #{plain(held[:bastion])}, " \
          "OVERWRITING those schemas there#{drop}"
      end

      # What a roll's answer hands on to the policies that follow it: the project to find the smoke
      # in, whether to request the smoke (not when the record opted out or the project has no smoke
      # script, either of which is noted on the record), and which roll asked.
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

      # Runs one generated script, found for the record's project, from its own directory. Answers
      # what it printed, or refuses with its status, that status's meaning and its output.
      def run_script(name, held, env, label, statuses, args: [], answering: [])
        script = script_for(name, plain(held[:project]), plain(held[:script]))
        result = Shell.new.capture("bash", script, *args, env: env, chdir: File.dirname(script))
        report = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")
        return { report: { value: report } } if result.ok?

        code = result.status.exitstatus
        return { report: { value: report }, status: code } if answering.include?(code)

        raise ConsoleCapture::Failure, "#{label} ended #{code} (#{statuses.fetch(code, "unexpected")})\n#{report}"
      end

      # The script a project runs: the override, else the named one in the project itself, else the
      # only one beneath it (not under `node_modules`, `vendor` or `.git`).
      def script_for(name, project, override)
        return existing_script(override) if override

        root = File.expand_path(project.to_s)
        beside = File.join(root, name)
        return beside if File.file?(beside)

        found = Dir.glob(File.join(root, "**", name)).grep_v(%r{/(node_modules|vendor|\.git)/})
        return found.first if found.one?

        raise ConsoleCapture::Failure, ambiguity(name, root, found.sort)
      end

      def ambiguity(name, root, found)
        return "no #{name} under #{root}; generate the AwsBox recipe or pass script=<path>" if found.empty?

        "#{found.size} #{name} files under #{root}; pass script=<path>: #{found.join(", ")}"
      end

      def existing_script(path)
        script = File.expand_path(path.to_s)
        File.file?(script) ? script : raise(ConsoleCapture::Failure, "no such script: #{script}")
      end

      # The variables the generated script reads, set only when the record asks for them.
      def smoke_env(held)
        { "TASKDEF" => plain(held[:taskdef]), "SKIP_POST_DEPLOY_SMOKE" => flag(held[:skip]),
          "SMOKE_ASYNC" => flag(held[:async]), "DRY_RUN" => flag(held[:dry_run]) }.compact
      end

      def flag(argument) = plain(argument) == true ? "1" : nil

      def child(ask, argv)
        tree = Codebase::Tree.new
        tree.require_checkout!
        run(tree, ask, argv)
      end

      def run(tree, ask, argv)
        result = Codebase::RubyChild.new(tree).capture(SCRIPTS.fetch(ask), *argv)
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      # A project path the tool can read from `root`: relative to it when it lies beneath it, so a
      # recipe made in a checkout names `examples/pizzas`, else absolute.
      def project_path(path, root)
        absolute = File.expand_path(path)
        absolute.start_with?("#{root}/") ? absolute.delete_prefix("#{root}/") : absolute
      end

      def message_of(result)
        text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
        text.empty? ? "the tool ended with status #{result.status.exitstatus}" : text
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
