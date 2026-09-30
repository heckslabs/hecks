# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "optparse"

module Hecks
  module CLI
    # One run of the checks against one service.
    class SmokeHttp
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
          else raise ArgumentError, "unknown scheme #{scheme.inspect}; expected one of #{SCHEMES.join(', ')}"
          end
        end

        # Computes the keyed digest every scheme is built from.
        def digest(secret, text)
          OpenSSL::HMAC.hexdigest("SHA256", secret, text)
        end
      end

      # Runs the checks as the `bin/smoke_http` script does: settings from the arguments and the
      # environment, a refusal worded with the program's name.
      #
      # @param argv [Array<String>] the flags, consumed
      # @param env [Hash{String => String}] the environment defaults
      # @param program [String] the name a refusal is prefixed with
      # @return [Integer] the exit status: 1 when any check failed
      # @raise [SystemExit] when the settings are refused
      def self.main(argv, env: ENV, program: "bin/smoke_http")
        new(settings(argv, env)).run
      rescue ArgumentError, OptionParser::ParseError, Errno::ENOENT => e
        abort "#{program}: #{e.message}"
      end

      # Reads the command line and environment into the settings a run needs.
      #
      # @param argv [Array<String>] the flags, consumed
      # @param env [Hash{String => String}] the environment defaults
      # @return [Hash{Symbol => String}] the settings
      # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
      def self.settings(argv, env)
        options = {}
        parser(options).parse!(argv)
        resolve(options, env)
      end

      # Merges explicit options over the environment's defaults and validates the result.
      #
      # @param options [Hash{Symbol => String}] the settings offered explicitly
      # @param env [Hash{String => String}] the environment defaults
      # @return [Hash{Symbol => String}] the settings
      # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
      def self.resolve(options, env)
        settings = {
          url: env.fetch("SMOKE_TARGET_URL", "http://127.0.0.1:4322"), path: env["SMOKE_WEBHOOK_PATH"],
          secret: env["SMOKE_WEBHOOK_SECRET"], header: env.fetch("SMOKE_SIGNATURE_HEADER", "X-Signature"),
          scheme: env.fetch("SMOKE_SIGNATURE_SCHEME", "timestamped")
        }.merge(options)
        validate!(settings)
        settings
      end

      # @api private
      def self.parser(options)
        OptionParser.new do |parser|
          %i[url path secret header scheme payload health_path state_path].each do |name|
            flag = "--#{name.to_s.tr('_', '-')}"
            parser.on("#{flag} VALUE") { |value| options[name] = value }
          end
          parser.on("--payload-file FILE") { |file| options[:payload] = File.read(file) }
        end
      end

      # Refuses settings a run cannot start from.
      #
      # @param settings [Hash{Symbol => String}] the settings to judge
      # @return [void]
      # @raise [ArgumentError] if the path or the secret is missing or the scheme is unknown
      def self.validate!(settings)
        raise ArgumentError, "no webhook path: pass --path or set SMOKE_WEBHOOK_PATH" if settings[:path].to_s.empty?
        raise ArgumentError, "no signing secret: set SMOKE_WEBHOOK_SECRET (or pass --secret)" if settings[:secret].to_s.empty?
        return if Signature::SCHEMES.include?(settings[:scheme])

        raise ArgumentError, "unknown scheme #{settings[:scheme].inspect}; expected one of #{Signature::SCHEMES.join(', ')}"
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

      def check(label)
        @out.print "  #{label}... "
        yield
        @out.puts "ok"
      rescue StandardError => e
        @out.puts "FAILED: #{e.message}"
        @failures << label
      end

      def check_health
        return unless @settings[:health_path]

        check("GET #{@settings[:health_path]} answers 200") { expect_status(get(@settings[:health_path]), 200) }
      end

      def check_unsigned
        check("a delivery with no signature is refused") { expect_refused(post(payload, {})) }
      end

      def check_wrong_secret
        check("a delivery signed with the wrong secret is refused") do
          expect_refused(post(payload, signature_header("not-the-secret-#{run_id}", payload)))
        end
      end

      # A trailing space is enough: the signature covers the exact bytes.
      def check_tampered_body
        check("a delivery whose body changed after signing is refused") do
          expect_refused(post("#{payload} ", signature_header(@settings.fetch(:secret), payload)))
        end
      end

      def check_signed
        check("a correctly signed delivery is accepted") { expect_success(post(payload, signed_headers)) }
      end

      def check_repeat
        check("a repeated delivery of the same payload is accepted again, not an error") do
          before = state
          expect_success(post(payload, signed_headers))
          after = state
          raise "the state changed on a repeated delivery:\n    before #{before}\n    after  #{after}" unless before == after
        end
      end

      def summarize
        if @failures.empty?
          @out.puts "\nSMOKE HTTP PASSED"
          0
        else
          @out.puts "\nSMOKE HTTP FAILED (#{@failures.size}):"
          @failures.each { |label| @out.puts "  - #{label}" }
          1
        end
      end

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

      def state
        @settings[:state_path] ? get(@settings[:state_path]).body : nil
      end

      def get(path)
        request(Net::HTTP::Get.new(URI.join(@target, path)))
      end

      def post(body, headers)
        req = Net::HTTP::Post.new(URI.join(@target, @settings.fetch(:path)))
        headers.each { |name, value| req[name] = value }
        req["Content-Type"] = "application/json"
        req.body = body
        request(req)
      end

      def request(req)
        options = { use_ssl: req.uri.scheme == "https", read_timeout: 8, open_timeout: 8 }
        Net::HTTP.start(req.uri.host, req.uri.port, **options) { |http| http.request(req) }
      end

      def expect_status(res, code)
        raise "expected #{code}, got #{res.code}" unless res.code.to_i == code
      end

      def expect_success(res)
        raise "expected 2xx, got #{res.code}: #{res.body.to_s[0, 200]}" unless res.code.to_i.between?(200, 299)
      end

      def expect_refused(res)
        raise "expected a 4xx refusal, got #{res.code}" unless res.code.to_i.between?(400, 499)
      end
    end
  end
end
