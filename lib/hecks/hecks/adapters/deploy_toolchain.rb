# frozen_string_literal: true

require_relative "console_capture"
require_relative "shell"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"
require "hecks/projections/deploy/template_diff"
require_relative "bluebook_report"
require_relative "deploy_plans"
require_relative "deploy_toolchain/statuses"
require_relative "deploy_toolchain/scripts"
require_relative "deploy_toolchain/answers"

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
      include Statuses
      include Scripts
      include Answers

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
        run_script(Script.new(SMOKE_SCRIPT, "smoke", SMOKE_STATUS), held, smoke_env(held))
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
        script = Script.new(SERVICE_SCRIPT, "service roll", SERVICE_STATUS, [plain(held[:service])])
        answer = run_script(script, held, env)
        answer.merge(rolled(answer[:report][:value])).merge(carried(held, "service_roll"))
      end

      # Rolls the whole box with a project's generated `deploy-box.sh`, through
      # `hecks deploy box_roll.run`.
      #
      # @param held [Hash] the `BoxRoll` record: `project`, and `script`, `taskdef`, `tags` when set
      # @return [Hash{Symbol => Hash}] `report:` what the script printed
      # @raise [ConsoleCapture::Failure] when no script, or more than one, is found, or it ends
      #   non-zero; the message names its status and what it printed
      def roll_box(**held)
        answer = run_script(Script.new(BOX_SCRIPT, "box roll", BOX_STATUS, box_args(held)), held, {})
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

        require_confirm(held, "restore", plan)
        restore(held)
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
        script = Script.new(VERIFY_SCRIPT, "verify", {}, copy_args(held), [DRIFT_STATUS])
        answer = run_script(script, held, env)
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
        planned = gate_preview(held, action)
        return planned if planned

        env = { "BRANCH" => plain(held[:branch]) }.compact
        answer = run_script(Script.new(PREVIEW_SCRIPT, "preview #{action}", PREVIEW_STATUS, [action]), held, env)
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
        plan = companion_plan(held, name, companion)
        return planned_answer(plan) if plain(held[:dry_run]) == true

        require_confirm(held, "roll #{companion}", plan)
        script = Script.new(name, "companion roll", COMPANION_STATUS, [plain(held[:taskdef])])
        run_script(script, held, {}).merge(planned: { value: false })
      end

      private

      # A project path the tool can read from `root`: relative to it when it lies beneath it, so a
      # recipe made in a checkout names `examples/pizzas`, else absolute.
      def project_path(path, root)
        absolute = File.expand_path(path)
        absolute.start_with?("#{root}/") ? absolute.delete_prefix("#{root}/") : absolute
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
