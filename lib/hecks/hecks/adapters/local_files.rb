# frozen_string_literal: true

require_relative "console_capture"
require_relative "../../cli/project_cli"

module Hecks
  module Adapters
    # The `Workspace` port's adapter: writes files into the project the operator is standing in.
    #
    # Custodian commands whose whole effect is files on disk ask it, so the journal records that a
    # write was requested and what came of it, and the writing happens here and nowhere else.
    class LocalFiles
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Writes a command-line launcher beside each domain of the current directory, or beside the
      # named ones, through `Hecks::CLI::ProjectCli`. A launcher is a generated file that only
      # points at its domain, so an existing one is replaced and nothing else is touched.
      #
      # @param held [Hash] the `Door` record: `domains` (comma separated paths under the current
      #   directory; every domain found when absent)
      # @return [Hash{Symbol => Hash}] `output:` one line per launcher written
      # @raise [ConsoleCapture::Failure] when no launcher was written
      def write(**held)
        domains = plain(held[:domains]).to_s.split(",").map(&:strip).reject(&:empty?)
        text = ConsoleCapture.answer do
          CLI::ProjectCli.call(domains, program: "hecks project_cli", root: Dir.pwd, remove_stale_bin: false)
        end
        unless text.include?("->")
          reason = text.strip.empty? ? "no domain found" : text.strip
          raise ConsoleCapture::Failure, "no launcher written: #{reason}"
        end

        { output: { value: text } }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
