# frozen_string_literal: true

require "stringio"
require_relative "console_capture"
require_relative "../../cli/smoke_http"

module Hecks
  module Adapters
    # The `HostHttp` port's adapter: talks HTTP to a running service on an operator's behalf.
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

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
