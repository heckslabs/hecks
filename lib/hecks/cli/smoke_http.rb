# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "optparse"
require_relative "smoke_http/settings"
require_relative "smoke_http/checks"
require_relative "smoke_http/transport"

module Hecks
  module CLI
    # One run of the checks against one service.
    class SmokeHttp
      # Raised when a smoke check's request gets an answer other than the one it expects.
      class Failure < RuntimeError; end

      include Checks
      include Transport
      extend Settings

      # The signature header value for a body, per scheme.
      module Signature
        SCHEMES = %w[timestamped sha256 hex].freeze

        module_function

        # Signs a body the way the chosen scheme's sender would.
        def header_value(scheme, secret, body, at: Time.now)
          case scheme
          when "timestamped"
            stamp = at.to_i
            "t=#{stamp},v1=#{digest(secret, "#{stamp}.#{body}")}"
          when "sha256" then "sha256=#{digest(secret, body)}"
          when "hex" then digest(secret, body)
          else raise ArgumentError, "unknown scheme #{scheme.inspect}; expected one of #{SCHEMES.join(", ")}"
          end
        end

        # Computes the keyed digest every scheme is built from.
        def digest(secret, text)
          OpenSSL::HMAC.hexdigest("SHA256", secret, text)
        end
      end

      # Runs the checks as the `hecks smoke_http` script does: settings from the arguments and the
      # environment, a refusal worded with the program's name.
      #
      # @param argv [Array<String>] the flags, consumed
      # @param env [Hash{String => String}] the environment defaults
      # @param program [String] the name a refusal is prefixed with
      # @return [Integer] the exit status: 1 when any check failed
      # @raise [SystemExit] when the settings are refused
      def self.main(argv, env: ENV, program: "hecks smoke_http")
        new(settings(argv, env)).run
      rescue ArgumentError, OptionParser::ParseError, Errno::ENOENT => e
        abort "#{program}: #{e.message}"
      end

      # @param settings [Hash{Symbol => String}] validated settings
      # @param out [IO] where the checks are reported
      def initialize(settings, out: $stdout)
        @settings = settings
        @out = out
        @failures = []
        @target = URI(settings.fetch(:url))
      end

      def run
        @out.puts "== signed webhook checks against #{@target}#{@settings[:path]} =="
        check_health
        check_unsigned
        check_wrong_secret
        check_tampered_body
        check_signed
        check_repeat
        summarize
      end

      private

      def run_id
        @run_id ||= "smoke-#{Process.pid}-#{rand(1_000_000)}"
      end

      def payload
        @payload ||= @settings[:payload] || JSON.generate(id: run_id, type: "smoke.ping")
      end

      def signed_headers
        signature_header(@settings.fetch(:secret), payload)
      end

      def signature_header(secret, body)
        { @settings.fetch(:header) => Signature.header_value(@settings.fetch(:scheme), secret, body) }
      end
    end
  end
end
