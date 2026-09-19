require_relative "../caller"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../ports/authorization"

module Hecks
  module Runtime
    class CommandRules
      # Whether the caller may run this command at all — a `role` mismatch,
      # the one check that runs before any domain-state work, alongside the
      # argument gate rather than after it.
      #
      # **Two checks, not a replacement** — ADR 0025 §9's own caution against
      # "silently downgrading `role` to documentation" cuts both ways: a
      # caller who never named who they are (every caller before this) is
      # checked exactly the way it always has been, string equality
      # against the command's own `role`. Only a caller that also binds an
      # `actor_id` (`Hecks.as_caller(role:, actor_id:)`) reaches the
      # real check — a live lookup through `Ports::Authorization`, once the
      # command's domain has an authorization provider: its own chapter,
      # or a framework member it attaches, declaring `provides
      # "authorization"` (Governance, via `uses_framework "Governance"`).
      # Boot refuses a domain that declares a `role` and has no provider —
      # `Registry::Verification#refuse_ungoverned_roles!`. An identified caller is never
      # let back through the string fallback: a real identity that holds
      # no matching grant is refused, not waved through because it also
      # happens to type the right word.
      module Authorization
        # Refuses the command when the ambient caller (`Caller.current`) does not hold the role
        # the command declares.
        #
        # Opt-in, on both sides. No caller bound: unchecked, exactly as
        # today. No role declared: unchecked too — `role` is genuinely
        # optional in this language (roughly a third of banking's own
        # commands declare none), so a command that never named a role has
        # nothing to check a caller against.
        #
        # @param command [Bluebook::Command] the command about to run; its `role` is the one
        #   required, and a nil or empty role means no check
        # @param domain [String] name of the command's domain, whose authorization provider
        #   answers the check
        # @return [nil] when no caller is bound, no role is declared, or the caller is authorized
        # @raise [Runtime::Unauthorized] if an identified caller holds no live grant of the role
        #   where a provider is attached, or otherwise if the caller's role string differs
        # @raise [Runtime::WiringError] if an identified caller is checked and zero or more than
        #   one adapter implements the authorization port
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

          raise Unauthorized, RefusalWording.render("Unauthorized", "role_mismatch",
                                                    command: command.hecks_name, role: command.role,
                                                    caller_role: caller.role)
        end

        private

        # **Declared, not named** — `Registry#authorization_provider_for`.
        #
        # The provider's own commands are looked up too, not waved through
        # the string fallback: `Governance::RoleAssignment.Assign` declares
        # `role "Governance administrator"`, and an identified caller
        # dispatching it is checked against a live assignment of that role
        # like any other gated command (ADR 0025 §9). The Rust kernel's
        # `check_role` (`rust/src/kernel/repository.rs`) does the same. The
        # consequence is deliberate: the first administrator grant has to
        # come from a caller that binds no `actor_id` (the unchecked,
        # string-compared path) — a bootstrap step, not a hole.
        def governance_attached?(domain)
          !registry.authorization_provider_for(domain).nil?
        end
      end
    end
  end
end
