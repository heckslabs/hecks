//! The caller rule of ADR 0216: who may dispatch a command that declares a role or `policy_only`.
//!
//! Three callers reach a command. A **stated** caller names a role or an actor. The **unstated**
//! caller is an outside caller (a peer, a request, a launcher line) that named neither: the host
//! dispatches it under [`ANONYMOUS_ROLE`], which no command declares, so a role-gated command
//! refuses it as `Unauthorized`/`role_unstated`. A dispatch with no caller at all is the host
//! acting for itself (a replayed step, a host-internal dispatch) and is never checked.
//!
//! A policy reaction runs as the role its policy declares with `acts_as`; one that declares none
//! runs as the unstated caller when the cascade it belongs to was begun by a caller and the
//! step's `role_enforcement` is `enforce` (the default), and unchecked otherwise. A command marked
//! `policy_only` refuses every caller that is not a reaction. The Ruby runtime applies the same
//! rule in `Runtime::CommandRules::Authorization`; the conformance corpus holds the two to it.

use super::Refusal;
use std::cell::Cell;

/// The role an outside caller that stated none is dispatched under: no command declares it, so a
/// command that declares any role refuses it in the `role_unstated` wording.
pub const ANONYMOUS_ROLE: &str = "Anonymous";

/// The step key that carries the host's `HECKS_ROLE_ENFORCEMENT` mode when it is not `enforce`.
pub const ENFORCEMENT_KEY: &str = "role_enforcement";

thread_local! {
    // Whether the dispatch running on this thread is a policy reaction's.
    static REACTING: Cell<bool> = const { Cell::new(false) };
}

/// Whether `caller_role` and `caller_actor_id` are the unstated caller.
#[must_use]
pub fn unstated(caller_role: Option<&str>, caller_actor_id: Option<&str>) -> bool {
    caller_role == Some(ANONYMOUS_ROLE) && caller_actor_id.is_none()
}

/// Whether the dispatch on this thread is a policy reaction's.
#[must_use]
pub fn reacting() -> bool {
    REACTING.with(Cell::get)
}

/// Runs `body` as a policy reaction's dispatch, restoring the previous mark when it returns.
pub fn as_reaction<T>(body: impl FnOnce() -> T) -> T {
    let previous = REACTING.with(|flag| flag.replace(true));
    let answer = body();
    REACTING.with(|flag| flag.set(previous));
    answer
}

/// Refuses a `policy_only` command dispatched by a caller rather than a reaction. A dispatch with
/// no caller at all (a replay, the host's own) is let through, as a role check lets it through.
///
/// # Errors
///
/// `Refusal::Unauthorized` in the `policy_only` wording when a caller is bound and the dispatch
/// is not a reaction's.
pub fn check_policy_only(
    command_name: &str,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
) -> Result<(), Refusal> {
    if reacting() || (caller_role.is_none() && caller_actor_id.is_none()) {
        return Ok(());
    }
    Err(Refusal::Unauthorized(
        super::refusal_wording::UnauthorizedPolicyOnlyArgs {
            command: command_name,
        }
        .render_args(),
    ))
}

/// The `role_unstated` refusal of `command_name`, which declares `role` (`A or B` for several).
#[must_use]
pub fn unstated_refusal(command_name: &str, role: &str) -> Refusal {
    Refusal::Unauthorized(
        super::refusal_wording::UnauthorizedRoleUnstatedArgs {
            command: command_name,
            role,
        }
        .render_args(),
    )
}

/// How a cascade's reactions are dispatched, fixed by the step that began it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReactionCallers {
    /// Whether a reaction that declares no `acts_as` runs as the unstated caller.
    pub unstated_when_undeclared: bool,
}

impl ReactionCallers {
    /// The rule for a cascade begun by `caller_role`/`caller_actor_id` under `enforcement` (the
    /// step's `role_enforcement`; `None` is `enforce`). Only a caller under `enforce` checks the
    /// reactions it sets off; a replay or a host-internal step states no caller and checks none.
    #[must_use]
    pub fn for_step(
        caller_role: Option<&str>,
        caller_actor_id: Option<&str>,
        enforcement: Option<&str>,
    ) -> Self {
        let stated = caller_role.is_some() || caller_actor_id.is_some();
        let enforcing = enforcement.is_none_or(|mode| mode.trim().eq_ignore_ascii_case("enforce"));
        Self {
            unstated_when_undeclared: stated && enforcing,
        }
    }

    /// The role a policy's reaction is dispatched as: its `acts_as`, else the unstated caller when
    /// this cascade checks undeclared reactions, else none.
    #[must_use]
    pub const fn role_for(self, acts_as: Option<&'static str>) -> Option<&'static str> {
        match acts_as {
            Some(role) => Some(role),
            None if self.unstated_when_undeclared => Some(ANONYMOUS_ROLE),
            None => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{as_reaction, check_policy_only, reacting, ReactionCallers, ANONYMOUS_ROLE};

    #[test]
    fn a_policy_only_command_refuses_a_stated_caller_in_the_policy_only_wording() {
        let refusal = check_policy_only("Water", Some("Gardener"), None).unwrap_err();
        assert_eq!(
            refusal.to_string(),
            "Water refused — only a policy reaction may dispatch it, and a caller did"
        );
    }

    #[test]
    fn a_policy_only_command_refuses_the_unstated_caller() {
        assert!(check_policy_only("Water", Some(ANONYMOUS_ROLE), None).is_err());
    }

    #[test]
    fn a_policy_only_command_admits_a_reaction_whatever_role_it_acts_as() {
        assert!(as_reaction(|| check_policy_only("Water", Some("System"), None)).is_ok());
    }

    #[test]
    fn a_policy_only_command_admits_a_dispatch_with_no_caller() {
        assert!(check_policy_only("Water", None, None).is_ok());
    }

    #[test]
    fn the_reaction_mark_is_restored_after_the_reaction() {
        as_reaction(|| ());
        assert!(!reacting());
    }

    #[test]
    fn a_stated_cascade_under_enforce_runs_an_undeclared_reaction_as_the_unstated_caller() {
        let callers = ReactionCallers::for_step(Some("Clerk"), None, None);
        assert_eq!(callers.role_for(None), Some(ANONYMOUS_ROLE));
    }

    #[test]
    fn a_shadow_step_leaves_an_undeclared_reaction_unchecked() {
        let callers = ReactionCallers::for_step(Some("Clerk"), None, Some("shadow"));
        assert_eq!(callers.role_for(None), None);
    }

    #[test]
    fn a_step_with_no_caller_leaves_an_undeclared_reaction_unchecked() {
        assert_eq!(
            ReactionCallers::for_step(None, None, None).role_for(None),
            None
        );
    }

    #[test]
    fn a_declared_reaction_runs_as_its_acts_as_role_in_any_cascade() {
        assert_eq!(
            ReactionCallers::default().role_for(Some("System")),
            Some("System")
        );
    }
}
