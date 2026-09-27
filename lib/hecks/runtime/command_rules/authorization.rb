require_relative "../caller"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../ports/authorization"

module Hecks
  module Runtime
    class CommandRules
      # Refuses a command whose declared `role` the ambient caller does not hold.
      #
      # A caller with an `actor_id` is checked against live grants when the domain has an
      # authorization provider (ADR 0025); one without is compared by role string only.
      module Authorization
        # Refuses the command when the ambient caller (`Caller.current`) lacks its declared role.
        #
        # Opt-in on both sides: no caller bound, or no role declared, means no check.
        #
        # @param command [Bluebook::Command] the command about to run
        # @param domain [String] name of the command's domain, whose provider answers the check
        # @return [nil] when unchecked or authorized
        # @raise [Runtime::Unauthorized] if the caller holds no grant of the role (identified
        #   caller) or its role string differs (unidentified caller)
        # @raise [Runtime::WiringError] if zero or several adapters implement the port
        def refuse_role_mismatch(command, domain)
          caller = Caller.current
          return unless caller
          return if command.role.to_s.empty?

          authorized =
            if caller.actor_id && governance_attached?(domain)
              Ports::Authorization.holds_role?(registry, actor_id: caller.actor_id, role: command.role,
                                                          as_of: caller.as_of, scope: caller.scope)
            else
              caller.role == command.role
            end

          return if authorized

          raise Unauthorized, RefusalWording.render_site("Unauthorized", "role_mismatch",
                                                         command: command.hecks_name, role: command.role,
                                                         caller_role: caller.role)
        end

        private

        # The provider's own commands are checked too, so the first administrator grant must
        # come from a caller with no `actor_id` (the string-compared path).
        def governance_attached?(domain)
          !registry.authorization_provider_for(domain).nil?
        end
      end
    end
  end
end
