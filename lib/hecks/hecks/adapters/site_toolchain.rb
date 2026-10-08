# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "shell"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"
require "hecks/tools"
require "hecks/tools/site_routes"
require "hecks/projections/site/live_edge"
require_relative "site_toolchain/prober"
require_relative "site_toolchain/role_prober"

module Hecks
  module Adapters
    # The `SiteToolchain` port's adapter: projects a site's route table into its `routes.ts`, or
    # checks the file on disk is current.
    #
    # The projection runs the `project_site` tool in this process, with its printing and exit status
    # captured: a tool that ends non-zero is a refusal whose reason is what it printed. The tool
    # ships in the gem and reads only the project it is given, so it needs no hecks checkout.
    class SiteToolchain
      # The `Hecks::Tools` tool the ask runs, by ask.
      SCRIPTS = { project: "project_site" }.freeze

      # The tool's flag for each `SiteProjection` field that takes a value.
      FLAGS = { "out" => :out, "template" => :template, "cms" => :cms, "root" => :root, "editor" => :editor,
                "extension" => :extension }.freeze

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a project's `routes.ts` from its declared route table, or with `check` only compares.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, and `out`, `template`, `cms`,
      #   `root`, `editor`, `extension` and `check` when set
      # @return [Hash{Symbol => Hash}] `output:` one line per file written or found current
      # @raise [ConsoleCapture::Failure] when the route table is refused (an unknown cache class,
      #   a duplicate path), a path or the extension is refused, or under `check` a file is out
      #   of date
      def project(**held)
        result = Codebase::RubyChild.new(Codebase::Tree.new).capture(SCRIPTS.fetch(:project), *project_flags(held),
                                                                     located(:domain, held[:domain]))
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      # Compares the CloudFront behaviours a project's edge generates with a live distribution's.
      # The live configuration is read from a saved `get-distribution-config` answer (`live`) or
      # fetched with that one read-only call (`distribution`, the distribution's id); nothing is
      # changed on either side.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, and `live` or `distribution`,
      #   with `template` (stands in for the Edge row's own; never read), `expect_new` (path
      #   patterns, comma separated) and `refs` (`!Ref Name=id` words, comma separated) when set
      # @return [Hash{Symbol => Hash}] `output:` the report of a distribution that matches
      # @raise [ConsoleCapture::Failure] when the project has no edge, the live configuration
      #   cannot be read, or the two differ; the message is the report
      def compare(**held)
        edge = edge_of(located(:domain, held[:domain]), located(:template, held[:template]))
        comparison = compared(edge, live_configuration(held), held)
        raise ConsoleCapture::Failure, comparison.to_s unless comparison.clean?

        { output: { value: comparison.to_s } }
      end

      # Asks a running site what its route table says it must answer, and judges each answer. It
      # sends anonymous requests only, follows no redirect, and changes nothing on the site: an
      # admin route is asked without a session and must refuse.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, `run` and `url`, the site's base
      #   address
      # @return [Hash{Symbol => Hash}] `output:` one line per check, ending in the count
      # @raise [ConsoleCapture::Failure] when the address is not http(s) or an answer is wrong; the
      #   message is the report
      def probe(**held)
        rows = table_of(located(:domain, held[:domain])).rows
        report, failed = Prober.new(rows, run: plain(held[:run]).to_s, base: base_url(plain(held[:url]))).call
        raise ConsoleCapture::Failure, report if failed.positive?

        { output: { value: report } }
      end

      # Dispatches every command a project declares a role for to a host with no role and no actor,
      # and checks the host refuses each as `Unauthorized`. The host must be on this machine and
      # enforcing roles (`HECKS_ROLE_ENFORCEMENT=enforce`); one that is not would run the commands.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, the project that declares the
      #   commands, and `url`, the host's base address
      # @return [Hash{Symbol => Hash}] `output:` one line per command, ending in the count
      # @raise [ConsoleCapture::Failure] when the host is not on this machine, or a command is not
      #   refused for its role; the message is the report
      def roles(**held)
        checks = Projections::Site::RoleProbe.checks(registry_of(located(:domain, held[:domain])))
        report, failed = RoleProber.new(checks, base: base_url(plain(held[:url]))).call
        raise ConsoleCapture::Failure, report if failed.positive?

        { output: { value: report } }
      end

      private

      # The scheme, host and port of an http(s) address.
      def base_url(url)
        uri = URI.parse(url.to_s)
        raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && uri.host

        "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
      rescue URI::InvalidURIError
        raise ConsoleCapture::Failure, "url must be an http(s) address, got #{url.inspect}"
      end

      # The flags `project_site` is run with: each the record names, and `--check` when asked.
      def project_flags(held)
        flags = FLAGS.filter_map { |flag, key| "--#{flag}=#{located(key, held[key])}" unless plain(held[key]).nil? }
        flags << "--check" if plain(held[:check]) == true
        flags
      end

      # The comparison of the project's edge with the live configuration.
      def compared(edge, live, held)
        live_edge = Projections::Site::LiveEdge
        live_edge.new(edge, live, expect_new: words(held[:expect_new]),
                                  refs:       live_edge.refs_from(plain(held[:refs]))).call
      end

      # The project's checked edge, read the way `project_site` reads it.
      def edge_of(root, template = nil)
        registry, chapter, table = read_table(root)
        site = Projections::Site
        site::Edge.read(chapter, table: table, template: template, vocabulary: site::Table.vocabulary(registry)) ||
          raise(ConsoleCapture::Failure, "#{root} declares no Edge rows")
      end

      # The project's checked route table.
      def table_of(root) = read_table(root).last

      # The registry the project at `root` boots into.
      def registry_of(root)
        registry = nil
        outcome = ConsoleCapture.capture { registry = Tools::SiteRoutes.registry_for(root) }
        raise ConsoleCapture::Failure, outcome.output.strip unless outcome.ok?

        registry
      end

      # The registry, chapter and checked table of the project at `root`.
      def read_table(root)
        registry = registry_of(root)
        chapter = Projections::Site::Table.chapter(registry)
        [registry, chapter, Projections::Site::Table.read(chapter, registry: registry)]
      rescue Projections::Site::Table::Invalid => e
        raise ConsoleCapture::Failure, e.message
      end

      def live_configuration(held)
        file = plain(held[:live])
        id = plain(held[:distribution])
        text = file ? read_saved(file) : fetch(id)
        JSON.parse(text)
      rescue JSON::ParserError => e
        raise ConsoleCapture::Failure, "the live configuration is not JSON: #{e.message.lines.first.strip}"
      end

      def read_saved(path)
        File.read(File.expand_path(path))
      rescue SystemCallError => e
        raise ConsoleCapture::Failure, "cannot read the live configuration: #{e.message}"
      end

      # The one AWS call: reading a distribution's configuration.
      def fetch(id)
        result = Shell.new.capture("aws", "cloudfront", "get-distribution-config", "--id", id.to_s)
        return result.out if result.ok?

        raise ConsoleCapture::Failure, "aws cloudfront get-distribution-config failed: #{message_of(result)}"
      end

      def words(argument) = plain(argument).to_s.split(",").map(&:strip).reject(&:empty?)

      def message_of(result)
        text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
        text.empty? ? "the tool ended with status #{result.status.exitstatus}" : text
      end

      # The tool runs from the tool's own root, so a path the caller gave relative to where they
      # stand is made absolute first; the extension is not a path.
      def located(key, argument)
        value = plain(argument)
        value.nil? || key == :extension ? value : File.expand_path(value)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
