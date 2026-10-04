# frozen_string_literal: true

require_relative "console_capture"
require_relative "codebase/tree"
require_relative "codebase/ruby_child"

module Hecks
  module Adapters
    # The `SiteToolchain` port's adapter: projects a site's route table into its `routes.ts`, or
    # checks the file on disk is current.
    #
    # The projection runs the `project_site` tool in a child of the checkout, with its printing and
    # exit status captured: a tool that ends non-zero is a refusal whose reason is what it printed.
    # Outside a hecks checkout the ask is refused with "needs a hecks checkout".
    class SiteToolchain
      # The `Hecks::Tools` tool the ask runs, by ask.
      SCRIPTS = { project: "project_site" }.freeze

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a project's `routes.ts` from its declared route table, or with `check` only compares.
      #
      # @param held [Hash] the `SiteProjection` record: `domain`, and `out` and `check` when set
      # @return [Hash{Symbol => Hash}] `output:` one line per file written or found current
      # @raise [ConsoleCapture::Failure] when the tree is not a checkout, the route table is
      #   refused (an unknown cache class, a duplicate path), or under `check` a file is out of date
      def project(**held)
        flags = []
        flags << "--out=#{plain(held[:out])}" unless plain(held[:out]).nil?
        flags << "--check" if plain(held[:check]) == true
        tree = Codebase::Tree.new
        tree.require_checkout!
        result = Codebase::RubyChild.new(tree).capture(SCRIPTS.fetch(:project), *flags, plain(held[:domain]))
        raise ConsoleCapture::Failure, message_of(result) unless result.ok?

        { output: { value: result.out } }
      end

      private

      def message_of(result)
        text = [result.err, result.out].map(&:strip).reject(&:empty?).join("\n")
        text.empty? ? "the tool ended with status #{result.status.exitstatus}" : text
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
