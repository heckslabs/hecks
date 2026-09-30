# frozen_string_literal: true

require_relative "console_capture"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"
require_relative "../../projections/deploy/template_diff"

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

      # `bin/project_deploy`'s flag for each `Recipe` field it takes.
      GENERATE_FLAGS = { "--tenant" => :tenant, "--schema" => :schema, "--out" => :out,
                         "--environment" => :environment }.freeze

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a domain's deploy recipe (the template, scripts and Makefile) from its declared
      # `deployed_to` target, through `bin/project_deploy`.
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
      # `bin/lint_deploy_recipes`.
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
      # `bin/project_oidc`.
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

      private

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
