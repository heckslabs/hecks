# frozen_string_literal: true

require_relative "console_capture"
require_relative "shell"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"
require "hecks/projections/deploy/template_diff"

module Hecks
  module Adapters
    # The `DeployToolchain` port's adapter: generates a domain's deploy recipe, lints and compares
    # what was generated, and projects the OIDC manifests.
    #
    # The recipe, the lint and the manifests run the `Hecks::Tools` tool that already does the work,
    # in this process with its printing and exit status captured: a tool that ends non-zero is a
    # refusal whose reason is what it printed. They write into a hecks checkout, so outside one the
    # ask is refused with "needs a hecks checkout". A comparison needs no checkout.
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

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a domain's deploy recipe (the template, scripts and Makefile) from its declared
      # `deployed_to` target, through `hecks deploy recipe.project`.
      #
      # @param held [Hash] the `Recipe` record: `domain`, and `tenant`, `schema`, `out` and
      #   `environment` when set
      # @return [Hash{Symbol => Hash}] `output:` one line per file written
      # @raise [ConsoleCapture::Failure] when the tree is not a checkout, or the generator refuses
      #   (no `deployed_to` target, conflicting settings, a schema with no tenant)
      def generate(**held)
        flags = GENERATE_FLAGS.filter_map { |flag, key| "#{flag}=#{plain(held[key])}" unless plain(held[key]).nil? }
        child(:generate, [*flags, plain(held[:domain])])
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
        answer.merge(taskdef: wrapped(match&.[](1)), tag: wrapped(match&.[](2))).merge(carried(held))
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
        answer.merge(carried(held)).merge(taskdef: wrapped(plain(held[:taskdef])))
      end

      private

      # What a roll's answer hands on to the policy that requests the smoke: the project to find the
      # smoke script in, and whether the record opted out of it.
      def carried(held)
        { project: { value: plain(held[:project]) }, skip_smoke: { value: plain(held[:skip_smoke]) == true } }
      end

      def wrapped(text) = text.to_s.empty? ? nil : { value: text }

      # What `deploy-box.sh` takes: a task definition, or `name=tag` words.
      def box_args(held) = [plain(held[:taskdef]), *plain(held[:tags]).to_s.split].compact

      # Runs one generated script, found for the record's project, from its own directory. Answers
      # what it printed, or refuses with its status, that status's meaning and its output.
      def run_script(name, held, env, label, statuses, args: [])
        script = script_for(name, plain(held[:project]), plain(held[:script]))
        result = Shell.new.capture("bash", script, *args, env: env, chdir: File.dirname(script))
        report = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")
        return { report: { value: report } } if result.ok?

        code = result.status.exitstatus
        raise ConsoleCapture::Failure, "#{label} ended #{code} (#{statuses.fetch(code, 'unexpected')})\n#{report}"
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

        "#{found.size} #{name} files under #{root}; pass script=<path>: #{found.join(', ')}"
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
        result = Codebase::RubyChild.new(tree).capture(SCRIPTS.fetch(ask), *argv)
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      def message_of(result)
        text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
        text.empty? ? "the tool ended with status #{result.status.exitstatus}" : text
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
