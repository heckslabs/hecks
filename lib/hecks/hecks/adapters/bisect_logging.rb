# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "bisect_log_marker"

module Hecks
  module Adapters
    # The `Logging` port's adapter for `BisectLog`: writes one entry of a repository's bisect log.
    # It decides nothing; the bluebook says when a red is searched or plain.
    class BisectLogging
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil, **)
        @git = Git.new
      end

      # @param held [Hash] the `BisectLog` record: `work`, `kind`, `finding`, `quote`, `checkout`
      # @return [Hash{Symbol => Hash}] `output:` what was recorded
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def record(**held)
        entry = marker_of(held).record!(**facts(held))
        { output: { value: "#{facts(held)[:work]}: #{entry["kind"]} #{entry["finding"]}".strip } }
      end

      private

      def facts(held) = %i[work kind finding quote].to_h { |name| [name, plain(held[name]).to_s] }

      def marker_of(held)
        result = @git.capture("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: plain(held[:checkout]) || Dir.pwd)
        raise ConsoleCapture::Failure, "git rev-parse: #{result.out.strip}" unless result.ok?

        BisectLogMarker.new(result.out.strip)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
