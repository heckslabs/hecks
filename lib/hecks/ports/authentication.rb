require_relative "../runtime/registry"

module Hecks
  module Ports
    # The OIDC handshake itself — building the URL a browser goes to,
    # and turning the code a provider sends back into a Hash of verified
    # claims (`issuer`, `subject`, `email`, `email_verified`). Resolved the same way every
    # other port here resolves its adapter: one adapter registry-wide
    # answers this, not a per-aggregate binding, since a domain has no
    # reason to want a different sign-in provider per aggregate.
    #
    # The other half of "who is this" — what a verified pair means to
    # this app, whether it resolves to an existing Identity — is
    # `Ports::IdentityResolution`'s job, not this one's. This port only
    # ever talks to the external provider; it never touches the
    # registry's own Identity/Governance data (it takes `registry`
    # purely to resolve which adapter answers it, same as every port
    # here already does).
    module Authentication
      NAME = "authentication".freeze

      # A sign-in that could not be verified — a state mismatch, a failed code
      # exchange, a missing or invalid ID token. An adapter wraps its own
      # libraries' errors into this, so a caller rescues one class whichever
      # provider answers the port.
      class ValidationError < StandardError
      end

      module_function

      # Builds the provider URL that starts a sign-in, with the CSRF state minted for it.
      #
      # The caller keeps the state (in a session, typically) and hands it back to `verify`
      # as `expected_state`.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Array(String, String)] the URL to send the browser to, then the fresh
      #   `state` value embedded in it
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      # @raise [KeyError] if the adapter's required configuration is unset
      #   (`GoogleAuthentication` reads `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and
      #   `GOOGLE_REDIRECT_URI` with no defaults)
      def authorization_url(registry)
        adapter(registry).authorization_url
      end

      # Exchanges the authorization code a provider sent back for a Hash of verified claims.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param code [String] the authorization code the provider sent back
      # @param state [String, nil] the state parameter the provider returned; nil is refused
      # @param expected_state [String, nil] the state `authorization_url` handed out before
      #   the redirect; nil is refused
      # @return [Hash{Symbol => Object}] the verified claims: `issuer:` and `subject:`
      #   (String), `email:` (String, or nil if the token carries none) and
      #   `email_verified:` (Boolean) — never the raw token
      # @raise [Ports::Authentication::ValidationError] if either state is nil or the two
      #   differ, the code exchange fails, the response has no ID token, or the ID token
      #   does not verify
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      # @raise [KeyError] if the adapter's required configuration is unset, or a verified
      #   token lacks an `iss` or `sub` claim
      def verify(registry, code:, state:, expected_state:)
        adapter(registry).verify(code: code, state: state, expected_state: expected_state)
      end

      # Finds the single adapter bound to this port, refusing an ambiguous wiring.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements this port,
      #   or the one that does has no Ruby implementation under `Hecks::Adapters`
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can authenticate a sign-in"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
