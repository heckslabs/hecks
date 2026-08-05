require_relative "../caller"
require_relative "../errors"
require_relative "../refusal_wording"

module Hecksagain
  module Runtime
    class CommandRules
      # Whether the caller may run this command at all — a `role` mismatch,
      # the one check that runs before any domain-state work, alongside the
      # argument gate rather than after it.
      module Authorization
        # OPT-IN, on BOTH sides. No caller bound: unchecked, exactly as
        # today. No role declared: unchecked too — `role` is genuinely
        # optional in this language (roughly a third of banking's own
        # commands declare none), so a command that never named a role has
        # nothing to check a caller against.
        def refuse_role_mismatch(command)
          caller = Caller.current
          return unless caller
          return if command.role.to_s.empty?
          return if caller.role == command.role

          raise Unauthorized, RefusalWording.render("Unauthorized", "role_mismatch",
                                                     command: command.hecks_name, role: command.role,
                                                     caller_role: caller.role)
        end
      end
    end
  end
end
