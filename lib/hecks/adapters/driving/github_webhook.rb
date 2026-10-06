require "openssl"
require "json"
require "rack"

module Hecks
  module Adapters
    # Driving adapters: code an outside caller reaches in through.
    module Driving
      # A GitHub webhook receiver, transport only: a rack app that verifies the signature.
      # A subclass implements `#handle_event(event, action, payload)` returning `[status, body]`.
      #
      # Not required by `require "hecks"`, so `rack` stays an opt-in dependency.
      class GithubWebhook
        # Raised for a request that cannot prove it came from GitHub; answered with a 401.
        class InvalidSignature < StandardError; end

        # Raised when a correctly signed body is not JSON; answered with a 400.
        class MalformedPayload < StandardError; end

        SIGNATURE_HEADER = "HTTP_X_HUB_SIGNATURE_256".freeze
        EVENT_HEADER     = "HTTP_X_GITHUB_EVENT".freeze

        # `secret:` has no default: a missing secret would silently disable verification.
        # @param secret [String] the shared webhook secret (e.g. `ENV.fetch
        #   ("GITHUB_WEBHOOK_SECRET")`), checked against each request's `X-Hub-Signature-256`
        # @raise [ArgumentError] if `secret` is nil or empty
        def initialize(secret:)
          raise ArgumentError, "no webhook secret configured" if secret.to_s.empty?

          @secret = secret
        end

        # The rack entry point: verifies, parses, and routes one webhook request.
        #
        # @param env [Hash] the rack environment
        # @return [Array(Integer, Hash, Array<String>)] the rack response triple — status,
        #   headers, and a one-element body Array holding the JSON-encoded response
        # @raise [NotImplementedError] if the subclass has not implemented `#handle_event`
        def call(env)
          request = Rack::Request.new(env)
          return respond(405, error: "MethodNotAllowed", message: "POST only") unless request.post?

          body = request.body.read
          verify_signature!(request, body)

          event = request.get_header(EVENT_HEADER)
          return respond(200, ok: true, event: "ping") if event == "ping"
          return respond(400, error: "MissingEvent", message: "no #{EVENT_HEADER} header") if event.to_s.empty?

          payload = parse_json(body)
          status, result = handle_event(event, payload["action"], payload)
          respond(status, result)
        rescue InvalidSignature => e
          respond(401, error: "InvalidSignature", message: e.message)
        rescue MalformedPayload => e
          respond(400, error: "MalformedPayload", message: e.message)
        end

        private

        # Constant-time compare: `==` leaks how many leading bytes of a forged signature matched.
        def verify_signature!(request, body)
          header = request.get_header(SIGNATURE_HEADER)
          raise InvalidSignature, "missing #{SIGNATURE_HEADER.sub("HTTP_", "").tr("_", "-")} header" if header.to_s.empty?

          digest   = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("sha256"), @secret, body)
          expected = "sha256=#{digest}"
          return if Rack::Utils.secure_compare(expected, header)

          raise InvalidSignature,
                "signature does not match — refusing a payload that cannot be proven to be GitHub's own"
        end

        def parse_json(body)
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise MalformedPayload, e.message
        end

        def handle_event(event, action, payload)
          raise NotImplementedError, "#{self.class} must implement #handle_event(event, action, payload)"
        end

        def respond(status, body)
          [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
        end
      end
    end
  end
end
