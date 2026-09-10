require "openssl"
require "json"
require "rack"

module Hecks
  module Adapters
    # THE DRIVING SIDE — code an OUTSIDE caller reaches IN through,
    # rather than code the domain reaches OUT through. Every existing
    # file under `adapters/driven/` is the latter: a store or reader a
    # `persisted_by`/`port` binding resolves TO, called BY this
    # framework's own runtime. Nothing under this repository has ever
    # been the mirror image before — code that receives a request FROM
    # the outside world and turns it into a dispatch — so this is the
    # first entry, and the directory itself is new.
    module Driving
      # A GITHUB WEBHOOK RECEIVER, TRANSPORT ONLY — the same split
      # `Hecks::Adapters::GithubChecks` (qa/adapters/github_checks.rb,
      # this class's own PULL-side sibling) already draws for itself:
      # THIS file owns proving a request really came from GitHub and
      # unwrapping GitHub's own webhook envelope (`X-GitHub-Event`, the
      # JSON body, GitHub's own automatic `ping` check) — never which
      # commands to dispatch about what it finds inside. That is exactly
      # as domain-specific as `GithubChecks#run` turning `check-runs`
      # JSON into green-or-raise, and lives exactly where that class's
      # own header explains such logic belongs: outside this library,
      # in `qa/adapters/github_ci_webhook.rb`, the subclass of this file
      # that actually knows what a `QualityControl::Clearance` is.
      #
      # A PLAIN RACK APP (`#call(env)`) — no Sinatra, no Rails — the same
      # shape `Hecks::Forms::App` (lib/hecks/forms/app.rb) already
      # established for the one other HTTP-facing surface this library
      # ships. `rack` is a LAZY Gemfile dependency for exactly the reason
      # that file's own header gives: this file is never required by
      # `require "hecks"` (nothing under `adapters.rb`'s own eager
      # `adapters/driven` load names it — see that file's own header),
      # so a project that never mounts a driving adapter never needs
      # `rack` installed, the same "opt in by requiring the file at all"
      # contract `hecks/forms.rb` already has for `Forms::App`.
      #
      # SUBCLASS RESPONSIBILITY: implement `#handle_event(event, action,
      # payload)`, returning `[http_status, response_body_hash]`. Called
      # ONLY after the signature has verified and the body has parsed as
      # JSON — a subclass never has to re-check either. `event` is
      # GitHub's own `X-GitHub-Event` header value ("check_suite",
      # "check_run", "pull_request", ...); `action` is the payload's own
      # top-level `"action"` field when it has one (GitHub's webhooks
      # nearly all carry one — "completed", "requested", "opened", ...)
      # and nil when it does not. `ping` — GitHub's own automatic
      # connectivity check, sent once when a webhook is first saved in
      # repository settings — is answered here and never reaches a
      # subclass at all; there is nothing domain-specific to decide
      # about it.
      class GithubWebhook
        # REFUSED, LOUDLY — the same shape a domain refusal already takes
        # everywhere else in this codebase (`Runtime::DOMAIN_REFUSALS`,
        # `Forms::App`'s own `{error:, message:}` JSON body for a bad
        # command). A request that cannot prove it came from GitHub gets
        # a real 401 and a named reason, never a silent 200 that would
        # let a forged "CI passed" payload regress nothing while looking
        # exactly like success in a log nobody re-reads.
        class InvalidSignature < StandardError; end

        # THE BODY DID NOT EVEN PARSE — distinct from a signature refusal:
        # this body genuinely came from whoever signed it (checked
        # FIRST, before parsing ever runs — see `#call`), and simply
        # is not JSON. Still refused, never guessed at.
        class MalformedPayload < StandardError; end

        SIGNATURE_HEADER = "HTTP_X_HUB_SIGNATURE_256".freeze
        EVENT_HEADER     = "HTTP_X_GITHUB_EVENT".freeze

        # `secret:` HAS NO DEFAULT, ON PURPOSE — the same rule
        # `GoogleAuthentication`'s own header states for its own
        # `ENV.fetch`, restated here because the consequence is worse for
        # a webhook: an unverified signature check is not "half
        # configured", it is NO verification at all, silently accepting
        # anything claiming to be GitHub. A caller passes the real
        # secret explicitly — from `ENV.fetch("GITHUB_WEBHOOK_SECRET")`
        # or wherever it keeps one — rather than this class reaching into
        # the environment itself and hiding that requirement inside a
        # default.
        def initialize(secret:)
          raise ArgumentError, "no webhook secret configured" if secret.to_s.empty?

          @secret = secret
        end

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

        # CONSTANT-TIME COMPARE, NOT `==`. A byte-by-byte `==` returns
        # the moment it finds the first mismatching byte, so how LONG
        # that took leaks how many leading bytes of a forged signature
        # were already right to anyone timing the response — GitHub's
        # own webhook documentation calls this out by name and recommends
        # exactly the constant-time compare `Rack::Utils.secure_compare`
        # already gives for free, reused rather than hand-rolled.
        def verify_signature!(request, body)
          header = request.get_header(SIGNATURE_HEADER)
          raise InvalidSignature, "missing #{SIGNATURE_HEADER.sub('HTTP_', '').tr('_', '-')} header" if header.to_s.empty?

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
