//! The `run` key a reaction gives a creating command that names none.
//!
//! Ruby's `ReactionInvocation::RunKeys.with_minted_run` mints the key from the identity port when
//! a reaction's explicit `with:` triggers a creating command whose `run` attribute is required
//! and the facts hold no `run`. The kernel has no identity adapter, so the port is the host's:
//! the input's `"identity"` is the ids it will hand out, in order, and when that script is
//! spent or absent the host is asked for the `identity_generation` fact over the callback
//! protocol. With neither, the facts are left as they were, as Ruby leaves them when no identity
//! adapter is bound.
//!
//! Which commands require a `run` comes from the host's input, not from generated code: the
//! top-level `"run_required"` is `["Domain::Aggregate.Command", ...]` (see `cli::run`).

use super::{needs, Json};
use std::cell::RefCell;
use std::collections::{HashSet, VecDeque};

/// The fact a host answers to supply a fresh identity.
pub const IDENTITY_FACT: &str = "identity_generation";

thread_local! {
    static REQUIRED: RefCell<HashSet<String>> = RefCell::new(HashSet::new());
    static IDENTITY: RefCell<VecDeque<String>> = RefCell::new(VecDeque::new());
}

/// Installs the commands that require a `run` and the ids the identity port will hand out (an
/// absent or malformed table installs an empty one).
pub fn install(required: Option<&Json>, identity: Option<&Json>) {
    let strings = |table: Option<&Json>| -> Vec<String> {
        table
            .and_then(Json::as_array)
            .unwrap_or(&[])
            .iter()
            .filter_map(|entry| entry.as_str().map(str::to_string))
            .collect()
    };
    REQUIRED.with(|r| *r.borrow_mut() = strings(required).into_iter().collect());
    IDENTITY.with(|i| *i.borrow_mut() = strings(identity).into());
}

/// The next identity: the script's, else the host's answer, else none.
fn next_identity() -> Option<String> {
    let scripted = IDENTITY.with(|i| i.borrow_mut().pop_front());
    scripted.or_else(|| {
        needs::ask_fact(IDENTITY_FACT, "String")
            .and_then(|answer| answer.as_str().map(str::to_string))
    })
}

/// `facts` with a minted `run` when `verb` requires one and none was given; unchanged otherwise.
pub fn with_minted_run(verb: &str, facts: Vec<(String, Json)>) -> Vec<(String, Json)> {
    let required = REQUIRED.with(|r| r.borrow().contains(verb));
    if !required || facts.iter().any(|(name, _)| name == "run") {
        return facts;
    }
    match next_identity() {
        Some(id) => {
            let mut minted = facts;
            minted.push(("run".to_string(), Json::obj(vec![("value", Json::str(id))])));
            minted
        }
        None => facts,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed(ids: &[&str]) {
        let ids = Json::Array(ids.iter().map(|id| Json::str(*id)).collect());
        install(
            Some(&Json::Array(vec![Json::str("D::A.Start")])),
            Some(&ids),
        );
    }

    fn run_of(facts: &[(String, Json)]) -> Option<String> {
        let (_, run) = facts.iter().find(|(name, _)| name == "run")?;
        run.get("value").and_then(Json::as_str).map(str::to_string)
    }

    #[test]
    fn a_required_run_is_minted_from_the_script_in_order() {
        installed(&["run-1", "run-2"]);
        let first = with_minted_run("D::A.Start", vec![]);
        let second = with_minted_run("D::A.Start", vec![]);
        assert_eq!(
            (run_of(&first), run_of(&second)),
            (Some("run-1".into()), Some("run-2".into()))
        );
    }

    #[test]
    fn a_run_the_facts_hold_is_kept_and_spends_no_id() {
        installed(&["run-1"]);
        let given = vec![(
            "run".to_string(),
            Json::obj(vec![("value", Json::str("mine"))]),
        )];
        let kept = with_minted_run("D::A.Start", given);
        let next = with_minted_run("D::A.Start", vec![]);
        assert_eq!(
            (run_of(&kept), run_of(&next)),
            (Some("mine".into()), Some("run-1".into()))
        );
    }

    #[test]
    fn a_command_that_does_not_require_a_run_is_left_alone() {
        installed(&["run-1"]);
        assert_eq!(run_of(&with_minted_run("D::A.Other", vec![])), None);
    }

    #[test]
    fn a_spent_script_with_no_host_leaves_the_facts_unchanged() {
        installed(&[]);
        assert_eq!(run_of(&with_minted_run("D::A.Start", vec![])), None);
    }
}
