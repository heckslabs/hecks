# frozen_string_literal: true

require_relative "console_capture"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"

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
      FLAGS = { "out" => :out, "template" => :template, "extension" => :extension }.freeze

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a project's `routes.ts` from its declared route table, or with `check` only compares.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, and `out`, `template`, `extension`
      #   and `check` when set
      # @return [Hash{Symbol => Hash}] `output:` one line per file written or found current
      # @raise [ConsoleCapture::Failure] when the route table is refused (an unknown cache class,
      #   a duplicate path), a path or the extension is refused, or under `check` a file is out
      #   of date
      def project(**held)
        flags = FLAGS.filter_map { |flag, key| "--#{flag}=#{located(key, held[key])}" unless plain(held[key]).nil? }
        flags << "--check" if plain(held[:check]) == true
        result = Codebase::RubyChild.new(Codebase::Tree.new).capture(SCRIPTS.fetch(:project), *flags,
                                                                     located(:domain, held[:domain]))
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      private

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
