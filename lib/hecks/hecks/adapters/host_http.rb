# frozen_string_literal: true

require "stringio"
require_relative "console_capture"
require "hecks/cli/smoke_http"
require "hecks/cli/check_era"

module Hecks
  module Adapters
    # The `HostHttp` port's adapter: talks HTTP to a running service on an operator's behalf, to
    # sign a webhook against it (`probe`) or to read the era it reports (`fetch`).
    #
    # The signing secret is read from `SMOKE_WEBHOOK_SECRET` and never from a command argument,
    # so it is not written to the journal or shown by `ps`.
    class HostHttp
      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Runs the signed-webhook and idempotency checks against a service.
      #
      # @param held [Hash] the `Operation` record: `url`, `path`, `header`, `scheme`, `payload`,
      #   `payload_file`, `health_path` and `state_path`
      # @return [Hash{Symbol => Hash}] `output:` the checks as reported
      # @raise [ArgumentError] if the path or the secret is missing, or the scheme is unknown
      # @raise [ConsoleCapture::Failure] when any check failed
      def probe(**held)
        options = %i[url path header scheme payload health_path state_path].to_h { |name| [name, plain(held[name])] }
        options[:payload] ||= File.read(plain(held[:payload_file])) if plain(held[:payload_file])

        out = StringIO.new
        status = CLI::SmokeHttp.new(CLI::SmokeHttp.resolve(options.compact, ENV), out: out).run
        raise ConsoleCapture::Failure, out.string.strip unless status.zero?

        { output: { value: out.string } }
      end

      # Reads the version and era a running `rust/host` reports and compares the era with an
      # allow-list file. A mismatch is an answer, not a refusal: the record keeps what was found.
      #
      # @param held [Hash] the `Host` record: `host` (the base URL), `expected` (the allow-list
      #   file) and `timeout` (seconds; 10 when absent)
      # @return [Hash{Symbol => Hash}] `era:`, `version:`, `verdict:` (`match`, `unlisted` or
      #   `mismatch`) and `report:` (the sentence `hecks check_era` prints)
      # @raise [ArgumentError] if no allow-list file was named
      # @raise [Errno::ENOENT] if the allow-list file cannot be read
      # @raise [Runtime::EraCheck::ExpectedEra::Unreachable] if the host cannot be reached
      # @raise [Runtime::EraCheck::ExpectedEra::BadResponse] if it answers no era
      def fetch(**held)
        file = plain(held[:expected]) or raise ArgumentError, "no allow-list file to compare the era with"
        finding = CLI::CheckEra.assess(plain(held[:host]), file, timeout: (plain(held[:timeout]) || 10).to_f)

        { era: { value: finding.verdict.era }, version: { value: finding.version },
          verdict: { value: finding.verdict.status.to_s }, report: { value: finding.line } }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
