module Hecks
  module Adapters
    module Driving
      class McpScope
        # Which of its allowed domains a restricted server answers a call in, and where it
        # dispatches. A server may read several domains; a command is allowed by name, so it is
        # dispatched only in the Hecks domain, never in another domain with a command of that name.
        module DomainReach
          # The Hecks domain, as the tail of its resolved path.
          HECKS_DOMAIN = "/lib/hecks/hecks".freeze

          # The domain a call may leave `domain:` out and get: the only one a restricted server
          # serves, or the Hecks domain when it serves several and it is one of them. Nil for an
          # unrestricted server and for several with no Hecks domain among them.
          #
          # @return [String, nil] the domain path as `HECKS_SERVER_DOMAINS` named it, resolved
          def default_domain
            return unless restricted?

            @allowed_domains.size == 1 ? @allowed_domains.first : hecks_domain
          end

          # @param domain [String, nil] the domain a call booted
          # @raise [Runtime::TypeMismatch] when the server serves several domains, one the Hecks
          #   domain, and the call booted another
          def admit_command_domain!(domain)
            return if domain.nil? || @allowed_domains.size < 2 || hecks_domain.nil?
            return if Storehouse.confine!(domain, "domain") == hecks_domain

            raise Runtime::TypeMismatch,
                  "domain: #{domain.inspect} is refused: this server runs in #{mode_label} " \
                  "and dispatches only in #{hecks_domain}"
          end

          private

          def hecks_domain = @allowed_domains.find { |path| path.end_with?(HECKS_DOMAIN) }
        end
      end
    end
  end
end
