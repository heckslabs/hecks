# = Hecks::HTTP::CsrfHelpers
#
# Shared mixin for CSRF protection of JSON/REST endpoints.
# Implements the double-submit cookie pattern with an Authorization-header
# exemption — browsers cannot auto-attach Authorization cross-site, so
# requests carrying that header are not vulnerable to CSRF.
#
# Usage:
#   include Hecks::HTTP::CsrfHelpers
#
#   def handle(req, res)
#     if csrf_required?(req) && !valid_csrf_json?(req)
#       res.status = 403
#       res["Content-Type"] = "application/json"
#       res.body = JSON.generate(error: "CSRF token mismatch")
#       return
#     end
#     # ...
#   end
#

module Hecks
  module HTTP
    module CsrfHelpers
      # Returns true when the request carries an Authorization header.
      # Browsers cannot auto-attach this header cross-site, so no CSRF risk.
      #
      # @param req the incoming request (WEBrick::HTTPRequest or compatible)
      # @return [Boolean]
      def token_authenticated?(req)
        auth = req["Authorization"]
        !auth.nil? && !auth.strip.empty?
      end

      # Parses the CSRF token from the Cookie header.
      #
      # @param req the incoming request
      # @return [String, nil] the cookie value or nil
      def read_csrf_cookie(req)
        cookie_header = req["Cookie"] || ""
        name = Hecks::Conventions::CsrfContract::COOKIE_NAME
        match = cookie_header.match(/(?:^|;\s*)#{Regexp.escape(name)}=([^;]+)/)
        match ? match[1] : nil
      end

      # Validates the CSRF double-submit: cookie value must equal X-CSRF-Token header.
      #
      # @param req the incoming request
      # @return [Boolean]
      def valid_csrf_json?(req)
        cookie_val  = read_csrf_cookie(req)
        header_val  = req[Hecks::Conventions::CsrfContract::HEADER_NAME]
        Hecks::Conventions::CsrfContract.valid?(cookie_val, header_val)
      end

      # Returns true when CSRF validation is needed:
      # mutating HTTP method AND no Authorization header present.
      #
      # @param req the incoming request
      # @return [Boolean]
      def csrf_required?(req)
        Hecks::Conventions::CsrfContract::MUTATING_METHODS.include?(req.request_method) &&
          !token_authenticated?(req)
      end

      # Sets the CSRF cookie on the response if not already present.
      # Returns the current (or newly generated) token.
      #
      # @param req the incoming request
      # @param res the outgoing response
      # @return [String] the CSRF token
      def ensure_csrf_cookie(req, res)
        existing = read_csrf_cookie(req)
        return existing if existing && !existing.empty?
        token = Hecks::Conventions::CsrfContract.generate_token
        res["Set-Cookie"] = Hecks::Conventions::CsrfContract.cookie_header(token)
        token
      end
    end
  end
end
