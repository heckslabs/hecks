require_relative "../caller"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../role_shadow"
require_relative "../../ports/authorization"
require_relative "unstated_caller"

module Hecks
  module Runtime
    class CommandRules
      # Refuses a caller who may not run a command: one that is not a reaction, of a command marked
      # `policy_only`; and one that does not hold the command's declared `role`.
      #
      # A caller with an `actor_id` is checked against live grants when the domain has an
      # authorization provider (ADR 0025); one without is compared by role string only. The
      # outside caller who stated no role (`Caller.unstated`, which a door binds) is refused by
      # name (ADR 0216), unless `HECKS_ROLE_ENFORCEMENT` is `shadow` or `off`. A dispatch with no
      # caller bound at all is the process acting for itself, as the Rust host's own dispatches
      # are, and is let through; `UnstatedCaller` counts both. The Rust kernel applies the same
      # rule (`kernel::caller_rule`, `check_role_via`).
      module Authorization
        include UnstatedCaller

        # Refuses the command when the ambient caller (`Caller.current`) may not run it. The
        # unstated caller is refused under `enforce` and counted otherwise; no caller at all is
        # counted and let through in every mode.
        #
        # @param command [Bluebook::Command] the command about to run
        # @param domain [String] name of the command's domain, whose provider answers the check
        # @param verb [String, nil] the command's fully qualified verb, for the shadow line
        # @return [nil] when unchecked, let through or authorized
        # @raise [Runtime::Unauthorized] if the command is `policy_only` and a caller dispatched
        #   it, if the caller stated no role, or if it holds no grant of the role (identified
        #   caller) or its role string differs (unidentified caller)
        # @raise [Runtime::WiringError] if zero or several adapters implement the port
        def refuse_role_mismatch(command, domain, verb: nil)
          refuse_caller_of_policy_only(command)
          roles = command.role_set
          return if roles.empty?

          caller = Caller.current
          return note_unstated_caller(command, domain, verb) if caller.nil?
          return refuse_unstated(command, domain, verb, roles) if Caller.unstated?(caller)
          return if roles.any? { |role| role_held?(caller, role, domain) }

          raise Unauthorized, RefusalWording.render_site("Unauthorized", "role_mismatch",
                                                         command: command.hecks_name, role: roles.join(" or "),
                                                         caller_role: caller.role)
        end

        private

        # A `policy_only` command admits a reaction and a dispatch with no caller, and refuses any
        # other caller; the unstated one only under `enforce`.
        def refuse_caller_of_policy_only(command)
          caller = Caller.current
          return unless command.policy_only? && caller && !Caller.reacting?
          # Under `shadow` and `off` the unstated caller is let through; the role check counts it.
          return if Caller.unstated?(caller) && !RoleShadow.enforcing?

          raise Unauthorized, RefusalWording.render_site("Unauthorized", "policy_only", command: command.hecks_name)
        end

        # The unstated caller is counted, then refused under `enforce` and let through otherwise.
        def refuse_unstated(command, domain, verb, roles)
          note_unstated_caller(command, domain, verb)
          return unless RoleShadow.enforcing?

          raise Unauthorized, RefusalWording.render_site("Unauthorized", "role_unstated",
                                                         command: command.hecks_name, role: roles.join(" or "))
        end

        # An identified caller holds the role by a live grant; an unidentified one by its string.
        def role_held?(caller, role, domain)
          return caller.role == role unless caller.actor_id && governance_attached?(domain)

          Ports::Authorization.holds_role?(registry, actor_id: caller.actor_id, role: role,
                                                     as_of: caller.as_of, scope: caller.scope)
        end

        # The provider's own commands are checked too, so the first administrator grant must
        # come from a caller with no `actor_id` (the string-compared path).
        def governance_attached?(domain)
          !registry.authorization_provider_for(domain).nil?
        end
      end
    end
  end
end
