require_relative "../runtime/registry"

module Hecks
  module Ports
    # THE OIDC HANDSHAKE ITSELF — building the URL a browser goes to,
    # and turning the code a provider sends back into a verified
    # (issuer, subject, email) triple. Resolved the same way every
    # other port here resolves its adapter: one adapter registry-wide
    # answers this, not a per-aggregate binding, since a domain has no
    # reason to want a different sign-in provider per aggregate.
    #
    # THE OTHER HALF of "who is this" — what a verified pair MEANS to
    # this app, whether it resolves to an existing Identity — is
    # `Ports::IdentityResolution`'s job, not this one's. This port only
    # ever talks to the external provider; it never touches the
    # registry's own Identity/Governance data (it takes `registry`
    # purely to resolve which adapter answers it, same as every port
    # here already does).
    module Authentication
      NAME = "authentication".freeze

      class ValidationError < StandardError
      end

      module_function

      def authorization_url(registry)
        adapter(registry).authorization_url
      end

      def verify(registry, code:, state:, expected_state:)
        adapter(registry).verify(code: code, state: state, expected_state: expected_state)
      end

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
