//! Aggregate-level invariant evaluation (f4)
//!
//! An invariant is a `given` checked on EVERY command instead of one. The
//! runtime evaluates each invariant's `holds_when` predicate against the
//! RESULTING state after a command's mutations (and lifecycle transition),
//! before save. When any predicate is false the command is rejected with an
//! InvariantViolation and zero events — the same shape a failed `given`
//! produces. The predicate machinery is reused wholesale from the `given`
//! evaluator (`runtime::interpreter::evaluate_predicate`) : an invariant and
//! a given speak the exact same single-line expression grammar.
//!
//! Usage:
//!   if let Some(violated) = check_invariants(&agg.invariants, &state, &attrs) {
//!       return Err(RuntimeError::InvariantViolation {
//!           name: violated.name.clone(),
//!           expression: violated.expression.clone(),
//!       });
//!   }

use crate::ir::Invariant;
use crate::runtime::interpreter::evaluate_predicate;
use crate::runtime::{AggregateState, Value};
use std::collections::HashMap;

/// Evaluate every invariant against the post-mutation state. Returns the
/// FIRST invariant whose predicate is false (in declaration order), or None
/// when all hold. Command attributes are passed through so an invariant can
/// reference the inbound command input the same way a `given` can, though
/// invariants typically read only the resulting state.
pub fn check_invariants<'a>(
    invariants: &'a [Invariant],
    state: &AggregateState,
    attrs: &HashMap<String, Value>,
) -> Option<&'a Invariant> {
    invariants
        .iter()
        .find(|inv| !evaluate_predicate(&inv.expression, state, attrs))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inv(name: &str, expr: &str) -> Invariant {
        Invariant { name: name.into(), expression: expr.into() }
    }

    #[test]
    fn passes_when_predicate_holds() {
        let mut state = AggregateState::new("s1");
        state.set("state", Value::Str("started".into()));
        state.set("verified", Value::Bool(false));
        let invs = vec![inv(
            "ready_means_verified",
            "state != \"ready_for_review\" && state != \"done\" || verified == true",
        )];
        assert!(check_invariants(&invs, &state, &HashMap::new()).is_none());
    }

    #[test]
    fn fails_when_ready_but_unverified() {
        let mut state = AggregateState::new("s1");
        state.set("state", Value::Str("ready_for_review".into()));
        state.set("verified", Value::Bool(false));
        let invs = vec![inv(
            "ready_means_verified",
            "state != \"ready_for_review\" && state != \"done\" || verified == true",
        )];
        let violated = check_invariants(&invs, &state, &HashMap::new());
        assert_eq!(violated.map(|i| i.name.as_str()), Some("ready_means_verified"));
    }

    #[test]
    fn passes_when_ready_and_verified() {
        let mut state = AggregateState::new("s1");
        state.set("state", Value::Str("ready_for_review".into()));
        state.set("verified", Value::Bool(true));
        let invs = vec![inv(
            "ready_means_verified",
            "state != \"ready_for_review\" && state != \"done\" || verified == true",
        )];
        assert!(check_invariants(&invs, &state, &HashMap::new()).is_none());
    }
}
