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
          # serves (the Hecks domain beside it, when it names the directory the domains sit in), or
          # the Hecks domain when it serves several and it is one of them. Nil for an unrestricted
          # server and for several with no Hecks domain among them.
          #
          # @return [String, nil] the domain path as `HECKS_SERVER_DOMAINS` named it, resolved
          def default_domain
            return unless restricted?

            @allowed_domains.size == 1 ? only_domain : hecks_domain
          end

          # A server reads each allowed domain and each directory directly under one, so a role
          # whose domains name `lib/hecks` reads the bluebooks beside the Hecks domain.
          #
          # @param path [String] a confined domain path
          # @return [Boolean] whether a read may name it
          def reads?(path)
            @allowed_domains.include?(path) || @allowed_domains.include?(File.dirname(path))
          end

          # A dispatch is allowed only in the Hecks domain, or in a domain `HECKS_SERVER_DOMAINS`
          # names when the server serves no Hecks domain among several; never in a directory that is
          # only read because it lies under an allowed one.
          #
          # @param domain [String, nil] the domain a call booted
          # @raise [Runtime::TypeMismatch] when the call booted another domain
          def admit_command_domain!(domain)
            return if domain.nil? || !commands_mode?

            path = Storehouse.confine!(domain, "domain")
            return if dispatch_domain?(path)

            raise Runtime::TypeMismatch,
                  "domain: #{domain.inspect} is refused: this server runs in #{mode_label} " \
                  "and dispatches only in #{dispatch_domains.join(", ")}"
          end

          private

          def hecks_domain = @allowed_domains.find { |path| path.end_with?(HECKS_DOMAIN) }

          # The one allowed domain, or the Hecks domain beside it when that one holds no bluebook of
          # its own and is the directory the domains sit in.
          def only_domain
            only = @allowed_domains.first
            home = File.join(only, "hecks")
            File.directory?(home) && Dir.glob(File.join(only, "*.bluebook")).empty? ? home : only
          end

          def dispatch_domain?(path) = dispatch_domains.include?(path)

          def dispatch_domains
            return [hecks_domain] if @allowed_domains.size > 1 && hecks_domain

            [*@allowed_domains, *@allowed_domains.map { |path| File.join(path, "hecks") }]
          end
        end
      end
    end
  end
end
