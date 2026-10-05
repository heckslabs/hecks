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

      # What each status of `smoke-after-deploy.sh` means, for the reason a refusal gives.
      SMOKE_STATUS = { 20 => "the roll did not settle", 21 => "gh missing or no repository, smoke not run",
                       22 => "the smoke failed", 23 => "the smoke's result is unknown" }.freeze

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
      # The script is the one the AwsBox projection writes; it waits for the roll to settle, then
      # dispatches and follows the smoke workflow, and only ever reads AWS. Its options travel in
      # the environment variables it documents.
      #
      # @param held [Hash] the `SmokeRun` record: `script`, and `taskdef`, `skip`, `async` and
      #   `dry_run` when set
      # @return [Hash{Symbol => Hash}] `report:` what the script printed
      # @raise [ConsoleCapture::Failure] when the script is missing, or ends non-zero; the message
      #   names the status (20 unsettled, 21 not run, 22 failed, 23 unknown) and what it printed
      def smoke(**held)
        script = File.expand_path(plain(held[:script]).to_s)
        raise ConsoleCapture::Failure, "no such script: #{script}" unless File.file?(script)

        result = Shell.new.capture("bash", script, env: smoke_env(held), chdir: File.dirname(script))
        report = [result.out, result.err].map(&:strip).reject(&:empty?).join("\n")
        return { report: { value: report } } if result.ok?

        code = result.status.exitstatus
        raise ConsoleCapture::Failure, "smoke ended #{code} (#{SMOKE_STATUS.fetch(code, 'unexpected')})\n#{report}"
      end

      private

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
