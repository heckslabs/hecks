require_relative "../runtime/registry"

module Hecks
  module Ports
    # The OIDC handshake: builds the provider URL and turns the returned code into verified claims.
    # One adapter registry-wide answers it; it never touches the registry's Identity data.
    module Authentication
      NAME = "authentication".freeze

      # A sign-in that could not be verified (state mismatch, failed code exchange, bad ID token).
      class ValidationError < StandardError
      end

      module_function

      # Builds the provider URL that starts a sign-in, with the CSRF state minted for it.
      #
      # The caller keeps the state and hands it back to `verify` as `expected_state`.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [Array(String, String)] the URL to send the browser to, then the fresh
      #   `state` value embedded in it
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      # @raise [KeyError] if the adapter's required configuration is unset
      def authorization_url(registry)
        adapter(registry).authorization_url
      end

      # Exchanges the authorization code a provider sent back for a Hash of verified claims.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param code [String] the authorization code the provider sent back
      # @param state [String, nil] the state parameter the provider returned; nil is refused
      # @param expected_state [String, nil] the state `authorization_url` returned; nil is refused
      # @return [Hash{Symbol => Object}] the verified claims: `issuer:`, `subject:`, `email:`
      #   (nil if the token carries none) and `email_verified:` -- never the raw token
      # @raise [Ports::Authentication::ValidationError] if a state is nil or they differ, the
      #   code exchange fails, or the ID token is missing or does not verify
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      # @raise [KeyError] if required configuration is unset, or the token lacks `iss`/`sub`
      def verify(registry, code:, state:, expected_state:)
        adapter(registry).verify(code: code, state: state, expected_state: expected_state)
      end

      # Finds the single adapter bound to this port.
      #
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
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
