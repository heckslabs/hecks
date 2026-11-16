require "openssl"
require "json"
require "rack"

module Hecks
  module Adapters
    # Driving adapters: code an outside caller reaches in through.
    module Driving
      # A GitHub webhook receiver, transport only: a rack app that verifies the signature.
      # A subclass implements `#handle_event(event, action, payload, delivery:)` returning
      # `[status, body]`; a ping it does not handle is answered here.
      #
      # Not required by `require "hecks"`, so `rack` stays an opt-in dependency.
      class GithubWebhook
        # Raised for a request that cannot prove it came from GitHub; answered with a 401.
        class InvalidSignature < StandardError; end

        # Raised when a correctly signed body is not JSON; answered with a 400.
        class MalformedPayload < StandardError; end

        # Raised when a body is longer than the receiver takes; answered with a 413.
        class PayloadTooLarge < StandardError; end

        SIGNATURE_HEADER = "HTTP_X_HUB_SIGNATURE_256".freeze
        EVENT_HEADER     = "HTTP_X_GITHUB_EVENT".freeze
        DELIVERY_HEADER  = "HTTP_X_GITHUB_DELIVERY".freeze

        # `secret:` has no default: a missing secret would silently disable verification.
        # @param secret [String] the shared webhook secret (e.g. `ENV.fetch
        #   ("GITHUB_WEBHOOK_SECRET")`), checked against each request's `X-Hub-Signature-256`
        # @param max_bytes [Integer, nil] the longest body taken; nil takes any length
        # @raise [ArgumentError] if `secret` is nil or empty
        def initialize(secret:, max_bytes: nil)
          raise ArgumentError, "no webhook secret configured" if secret.to_s.empty?

          @secret = secret
          @max_bytes = max_bytes
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

          answer(request)
        rescue PayloadTooLarge => e
          respond(413, error: "PayloadTooLarge", message: e.message)
        rescue InvalidSignature => e
          respond(401, error: "InvalidSignature", message: e.message)
        rescue MalformedPayload => e
          respond(400, error: "MalformedPayload", message: e.message)
        end

        private

        # Reads, verifies and routes one POST.
        def answer(request)
          body = read_body(request.body)
          verify_signature!(request, body)
          route(request, body)
        end

        # Reads at most one byte past `max_bytes`, so an overlong body is refused without being
        # read whole.
        def read_body(stream)
          return stream.read.to_s unless @max_bytes

          body = stream.read(@max_bytes + 1).to_s
          raise PayloadTooLarge, "a body over #{@max_bytes} bytes is refused" if body.bytesize > @max_bytes

          body
        end

        # Answers a missing event header itself; hands every event to `handle_event`.
        def route(request, body)
          event = request.get_header(EVENT_HEADER)
          return respond(400, error: "MissingEvent", message: "no #{EVENT_HEADER} header") if event.to_s.empty?

          payload = parse_json(body)
          delivery = request.get_header(DELIVERY_HEADER)
          status, result = handle_event(event, payload["action"], payload, delivery: delivery)
          respond(status, result)
        end

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

        # Answers a ping; any other event needs the subclass.
        def handle_event(event, _action, _payload, delivery: nil)
          return [200, { ok: true, event: "ping", delivery: delivery }.compact] if event == "ping"

          raise NotImplementedError, "#{self.class} must implement #handle_event(event, action, payload, delivery:)"
        end

        def respond(status, body)
          [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
        end
      end
    end
  end
end
