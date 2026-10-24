require "securerandom"

require_relative "../../ports/authentication"

module Hecks
  module Adapters
    # Google's OIDC handshake — the `authentication` port's adapter for Google
    # sign-in, via `oauth2` (code exchange) and `google-id-token` (verification).
    #
    # `oauth2`/`google-id-token` load lazily, inside the methods that use
    # them, so a domain that never binds this adapter never needs them installed.
    #
    # `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`/`GOOGLE_REDIRECT_URI` have no
    # defaults, on purpose: a half-configured login should refuse to boot.
    module GoogleAuthentication
      ISSUER = "https://accounts.google.com".freeze

      module_function

      # Builds the OAuth2 client for Google's token endpoints.
      #
      # @return [OAuth2::Client] a client configured for Google's OAuth2/OIDC endpoints
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

      # The URL to send a browser to, carrying a fresh CSRF `state` the caller
      # must stash (typically in a session) and check again in `verify`.
      #
      # @return [Array(String, String)] the URL to send the browser to, and the fresh CSRF
      #   `state` embedded in it
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

      # Exchanges `code` for tokens and verifies the ID token against Google's
      # JWKS; `email_verified` tells a caller if Google actually checked the email.
      # @param code [String] the authorization code the provider sent back
      # @param state [String, nil] the state parameter the provider returned; nil is refused
      # @param expected_state [String, nil] the state `authorization_url` handed out before
      #   the redirect; nil is refused
      # @return [Hash{Symbol => Object}] `issuer:` and `subject:` (String), `email:` (String,
      #   or nil if the token carries none), `email_verified:` (Boolean)
      # @raise [Ports::Authentication::ValidationError] if the state check, code exchange, or
      #   ID token verification fails
      # @raise [KeyError] if `GOOGLE_CLIENT_ID` or `GOOGLE_REDIRECT_URI` is unset, or a
      #   verified token lacks an `iss` or `sub` claim
      def verify(code:, state:, expected_state:)
        # Both requires happen up front: the rescue below matches
        # GoogleIDToken::ValidationError, resolved only when caught, so
        # requiring it lazily after an OAuth2::Error would mask the real failure.
        require "oauth2"
        require "google-id-token"

        raise Ports::Authentication::ValidationError, "state mismatch" unless state && expected_state && state == expected_state

        identity(GoogleIDToken::Validator.new.check(exchange(code), ENV.fetch("GOOGLE_CLIENT_ID")))
      rescue OAuth2::Error, GoogleIDToken::ValidationError => e
        raise Ports::Authentication::ValidationError, e.message
      end

      # Exchanges an authorization code for the provider's raw ID token.
      #
      # @param code [String] the authorization code the provider sent back
      # @return [String] the unverified ID token
      # @raise [Ports::Authentication::ValidationError] if the response carries no ID token
      def exchange(code)
        token = client.auth_code.get_token(code, redirect_uri: ENV.fetch("GOOGLE_REDIRECT_URI"))
        token.params["id_token"] or raise Ports::Authentication::ValidationError, "no id_token in the response"
      end

      # Reads the identity claims out of a verified ID token payload.
      #
      # @param payload [Hash{String => Object}] the verified token claims
      # @return [Hash{Symbol => Object}] the same shape `verify` returns
      def identity(payload)
        {
          issuer: payload.fetch("iss"), subject: payload.fetch("sub"),
          email: payload["email"], email_verified: [true, "true"].include?(payload["email_verified"])
        }
      end
    end
  end
end
