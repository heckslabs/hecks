# frozen_string_literal: true

require_relative "console_capture"
require_relative "../../cli/project_deploy"
require_relative "../../cli/project_oidc"
require_relative "../../projections/deploy/template_diff"

module Hecks
  module Adapters
    # What the Workspace port does for the Deploy chapter: renders a domain's deploy recipe, writes
    # each domain's OIDC manifest, and compares two rendered templates.
    #
    # Deploy commands are for clients, so they run anywhere and take the directory they run in as
    # the project. A recipe's default home is `deploy/<stack>` under it. Every method takes the
    # record of the request it answers, with value objects as `{ value: x }`, and refuses by
    # raising.
    module DeployFiles
      # Reads the target the domain's world declares, which decides whether a recipe renders.
      #
      # @param held [Hash] the `Recipe` record: `domain`, and `environment` when named
      # @return [Hash{Symbol => Hash}] `target:` the declared adapter's name, empty when none
      # @raise [ConsoleCapture::Failure] if the domain has no world file or overlay
      def survey(**held)
        target = CLI::ProjectDeploy.target(domain: plain(held[:domain]), environment: plain(held[:environment]))
        { target: { value: target.to_s } }
      rescue CLI::ProjectDeploy::Refusal => e
        raise ConsoleCapture::Failure, e.message
      end

      # Renders the recipe and writes it, through the same `CLI::ProjectDeploy` `bin/project_deploy`
      # runs.
      #
      # @param held [Hash] the `Recipe` record: `domain`, and `tenant`, `schema`, `out` and
      #   `environment` when set
      # @return [Hash{Symbol => Hash}] `report:` one `wrote <path>` line per file
      # @raise [ConsoleCapture::Failure] if the domain declares no deploy target or the request
      #   contradicts itself
      def render(**held)
        rendered = CLI::ProjectDeploy.call(
          domain: plain(held[:domain]), tenant: plain(held[:tenant]), schema: plain(held[:schema]),
          out: plain(held[:out]), environment: plain(held[:environment]), out_root: Dir.pwd
        )
        lines = rendered.written.map { |path| "wrote #{path}" }
        { report: { value: (lines + ["deploy from #{rendered.out_dir}: make deploy"]).join("\n") } }
      rescue CLI::ProjectDeploy::Refusal => e
        raise ConsoleCapture::Failure, e.message
      end

      # Writes an `oidc.json` beside each domain, through the same `CLI::ProjectOidc` that
      # `bin/project_oidc` runs.
      #
      # @param held [Hash] the `OidcManifest` record: `domains` (comma separated directories under
      #   the current one; every domain found when absent)
      # @return [Hash{Symbol => Hash}] `report:` one line per domain
      # @raise [ConsoleCapture::Failure] when no manifest was written
      def write_manifests(**held)
        wanted = plain(held[:domains]).to_s.split(",").map(&:strip).reject(&:empty?)
        outcomes = CLI::ProjectOidc.call(root: Dir.pwd, wanted: wanted)
        lines = outcomes.map { |o| o.error ? "#{o.path}: #{o.error}" : "#{o.path}/oidc.json  <-  #{o.chapter}" }
        raise ConsoleCapture::Failure, (lines.empty? ? "no domain found" : lines.join("\n")) unless outcomes.any? { |o| !o.error }

        { report: { value: lines.join("\n") } }
      end

      # Compares two CloudFormation templates offline, by logical id.
      #
      # @param before [Hash, String] the template as it was
      # @param after [Hash, String] the template as it is
      # @param json [Boolean] answer the report as JSON
      # @param strict [Boolean] count cosmetic differences (comments, key order) too
      # @return [String] the report
      # @raise [Runtime::NotFound] if a template cannot be read or parsed
      def diff(before:, after:, json: false, strict: false, **)
        comparer = Projections::Deploy::TemplateDiff
        report = comparer.diff_files(plain(before), plain(after), strict: plain(strict) == true)
        plain(json) == true ? comparer.render_json(report) : comparer.render(report)
      rescue ArgumentError => e
        raise Runtime::NotFound, e.message
      end
    end
  end
end
