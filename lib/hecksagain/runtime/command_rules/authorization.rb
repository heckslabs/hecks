require_relative "../caller"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../ports/authorization"

module Hecksagain
  module Runtime
    class CommandRules
      # Whether the caller may run this command at all — a `role` mismatch,
      # the one check that runs before any domain-state work, alongside the
      # argument gate rather than after it.
      #
      # TWO CHECKS, NOT A REPLACEMENT — ADR 0025 §9's own caution against
      # "silently downgrading `role` to documentation" cuts both ways: a
      # caller who never named WHO they are (every caller before this) is
      # checked exactly the way it always has been, string equality
      # against the command's own `role`. Only a caller that ALSO binds an
      # `actor_id` (`Hecksagain.as_caller(role:, actor_id:)`) reaches the
      # real check — a live Governance::RoleAssignment lookup through
      # `Ports::Authorization`, once the command's domain declares
      # `uses_framework "Governance"` (`HecksagonBuilder` refuses any
      # domain that declares a `role` and does not, at build time — see
      # its own `refuse_ungoverned_roles!`). An identified caller is never
      # let back through the string fallback: a real identity that holds
      # no matching grant is refused, not waved through because it also
      # happens to type the right word.
      module Authorization
        # OPT-IN, on BOTH sides. No caller bound: unchecked, exactly as
        # today. No role declared: unchecked too — `role` is genuinely
        # optional in this language (roughly a third of banking's own
        # commands declare none), so a command that never named a role has
        # nothing to check a caller against.
        def refuse_role_mismatch(command, domain)
          caller = Caller.current
          return unless caller
          return if command.role.to_s.empty?

          authorized =
            if caller.actor_id && governance_attached?(domain)
              Ports::Authorization.holds_role?(registry, actor_id: caller.actor_id, role: command.role)
            else
              caller.role == command.role
            end

          return if authorized

          raise Unauthorized, RefusalWording.render("Unauthorized", "role_mismatch",
                                                    command: command.hecks_name, role: command.role,
                                                    caller_role: caller.role)
        end

        private

        # SELF-EXEMPT, like `HecksagonBuilder#refuse_ungoverned_roles!` —
        # Governance IS the thing a `holds_role?` lookup runs against, so
        # its own commands are always checked by the string fallback, not
        # a lookup against itself.
        def governance_attached?(domain)
          domain.to_s == "Governance" || registry.hecksagon(domain)&.framework_members&.include?("Governance") || false
        end
      end
    end
  end
end
