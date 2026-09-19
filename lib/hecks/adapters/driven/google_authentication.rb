require "securerandom"

require_relative "../../ports/authentication"

module Hecks
  module Adapters
    # **Google's own OIDC handshake** — the `authentication` port's one real
    # implementation today, factored out of being hand-rolled per-app
    # (an embryonaut_console `google_auth.rb` once did exactly this by
    # hand); any hecks-based app gets Google sign-in for free now, the
    # same "one adapter, reusable everywhere" value every other adapter
    # in this directory already has.
    #
    # `oauth2` does only the authorization-code exchange (no Rack
    # middleware, no Omniauth strategy indirection) ; `google-id-token`
    # does only ID-token verification (signature checked against
    # Google's real, rotating JWKS — real, maintained code, never
    # hand-rolled here). Neither library decides what a verified
    # (issuer, subject) means — that's `Ports::IdentityResolution`'s
    # job, called by whoever consumes this port's `verify`.
    #
    # Lazy requires, same reasoning `Postgres.connect_for` already
    # holds itself to for `pg`: a domain that never binds
    # `authentication` to this adapter should never need these gems
    # installed. This file loads in every boot (driven.rb's own
    # unconditional require_relative list) ; the gems load only where
    # a real handshake actually happens.
    #
    # `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`/`GOOGLE_REDIRECT_URI` —
    # no defaults, on purpose: a login mechanism silently
    # half-configured is worse than one that refuses to boot at all.
    module GoogleAuthentication
      ISSUER = "https://accounts.google.com".freeze

      module_function

      # Builds a fresh `OAuth2::Client` configured for Google's own endpoints.
      #
      # @return [OAuth2::Client] a client configured with the app's client id/secret from
      #   `ENV` and Google's authorize/token URLs
      # @raise [KeyError] if `GOOGLE_CLIENT_ID` or `GOOGLE_CLIENT_SECRET` is unset
      def client
        require "oauth2"
        OAuth2::Client.new(
          ENV.fetch("GOOGLE_CLIENT_ID"), ENV.fetch("GOOGLE_CLIENT_SECRET"),
          site:          "https://oauth2.googleapis.com",
          authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
          token_url:     "/token"
        )
      end

      # Builds the Google sign-in URL a browser goes to, with a fresh CSRF state.
      #
      # The URL to send a browser to, carrying a fresh CSRF `state` the
      # caller is responsible for stashing (a session, typically) and
      # checking again in `verify`.
      #
      # @return [Array(String, String)] the authorization URL, then the fresh `state`
      #   value embedded in it
      # @raise [KeyError] if `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` or
      #   `GOOGLE_REDIRECT_URI` is unset
      def authorization_url
        state = SecureRandom.hex(24)
        url = client.auth_code.authorize_url(
          redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI"),
          scope:        "openid email profile",
          state:        state
        )
        [url, state]
      end

      # Exchanges an authorization code for a Hash of verified claims, confirming the CSRF
      # state along the way.
      #
      # Exchanges `code` for tokens, verifies the returned ID token's
      # signature and claims against Google's own JWKS, and confirms
      # `state` matches what `authorization_url` handed out — a
      # mismatch (or any failure in the exchange/verification itself)
      # is a Ports::Authentication::ValidationError, never a
      # silently-empty result. Returns
      # {issuer:, subject:, email:, email_verified:} on success — never
      # the raw token, never anything a caller would need to re-verify
      # itself. `email_verified` rides along because a caller granting
      # access off this email needs to know Google actually checked it.
      #
      # @param code [String] the authorization code Google sent back
      # @param state [String, nil] the state parameter Google returned
      # @param expected_state [String, nil] the state `authorization_url` handed out before
      #   the redirect
      # @return [Hash{Symbol => Object}] the verified claims: `issuer:` and `subject:`
      #   (String), `email:` (String, or nil if the token carries none) and
      #   `email_verified:` (Boolean)
      # @raise [Ports::Authentication::ValidationError] if either state is nil or the two
      #   differ, the code exchange fails, the response has no ID token, or the ID token
      #   does not verify
      # @raise [KeyError] if `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` or
      #   `GOOGLE_REDIRECT_URI` is unset, or the verified token lacks an `iss` or `sub` claim
      def verify(code:, state:, expected_state:)
        # **Both gems, before anything else** — not staggered further down
        # this method: the rescue clause below names GoogleIDToken
        # ::ValidationError, and Ruby resolves that constant reference
        # at the moment an exception is being matched, not at parse
        # time. An OAuth2::Error raised before a later `require
        # "google-id-token"` line ran would make the rescue clause
        # itself blow up on an undefined constant, masking the real
        # error. Requiring both up front means whichever one raises
        # first, the constant is already there to catch it.
        require "oauth2"
        require "google-id-token"

        raise Ports::Authentication::ValidationError, "state mismatch" unless state && expected_state && state == expected_state

        token = client.auth_code.get_token(code, redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI"))
        id_token = token.params["id_token"] or raise Ports::Authentication::ValidationError, "no id_token in the response"

        payload = GoogleIDToken::Validator.new.check(id_token, ENV.fetch("GOOGLE_CLIENT_ID"))
        {
          issuer: payload.fetch("iss"), subject: payload.fetch("sub"),
          email: payload["email"], email_verified: [true, "true"].include?(payload["email_verified"])
        }
      rescue OAuth2::Error, GoogleIDToken::ValidationError => e
        raise Ports::Authentication::ValidationError, e.message
      end
    end
  end
end
