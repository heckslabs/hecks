//! conception_kernel::produced_state — the facts a setup chain has produced.
//!
//! Threaded through the planner's recursion so a later precondition already
//! covered by an earlier step is skipped, and so an Append loop subtracts
//! existing instances (a MinSizeList chain doesn't double-seed). `satisfies`
//! EVALUATES the rule's `Satisfy` tree against produced facts — a generic
//! interpreter of boolean combinators over atomic predicates, with no per-kind
//! branch. The compound integer predicate is just a deeper tree.
//!
//! Example:
//!   let mut p = ProducedState::default();
//!   p.absorb(add_item_cmd);            // one Append on `items`
//!   assert_eq!(p.append_count("items"), 1);

use crate::ir::{Aggregate, Command, MutationOp};
use std::collections::{BTreeMap, BTreeSet};

use super::grammar::{KindRule, Precondition, Satisfy};

#[derive(Default)]
pub struct ProducedState {
    /// `(field, value)` pairs from `Set` mutations and lifecycle transitions.
    set_facts: BTreeSet<(String, String)>,
    /// Per-field count of `Append` mutations across chain steps.
    append_counts: BTreeMap<String, usize>,
    /// Fields raised by `Increment` (or the conservative Multiply/Decay/Clamp).
    incremented_fields: BTreeSet<String>,
}

impl ProducedState {
    /// Record a chain step's direct effects — Set/Append/Increment mutations and
    /// any lifecycle transition this command drives (a transition lands the
    /// lifecycle field at its to_state, the same as a Set, so a later
    /// from_state precondition sees it satisfied).
    pub fn absorb(&mut self, agg: &Aggregate, cmd: &Command) {
        for m in &cmd.mutations {
            match m.operation {
                MutationOp::Set => {
                    self.set_facts
                        .insert((m.field.clone(), m.value.trim_matches('"').to_string()));
                }
                MutationOp::Append => {
                    *self.append_counts.entry(m.field.clone()).or_insert(0) += 1;
                }
                // Increment raises the field; Multiply/Decay/Clamp touch it with
                // a value depending on prior state we don't track — treat all as
                // "raised", the same conservative path generator.rs takes.
                MutationOp::Increment | MutationOp::Multiply | MutationOp::Decay | MutationOp::Clamp => {
                    self.incremented_fields.insert(m.field.clone());
                }
                MutationOp::Decrement | MutationOp::Toggle | MutationOp::Delete | MutationOp::Remove => {}
            }
        }
        if let Some(lc) = &agg.lifecycle {
            for t in &lc.transitions {
                if t.command == cmd.name {
                    self.set_facts.insert((lc.field.clone(), t.to_state.clone()));
                }
            }
        }
    }

    pub fn append_count(&self, field: &str) -> usize {
        self.append_counts.get(field).copied().unwrap_or(0)
    }

    /// True when produced facts already satisfy `pre`, by evaluating the rule's
    /// `Satisfy` tree.
    pub fn satisfies(&self, pre: &Precondition, rule: &KindRule) -> bool {
        self.eval(&rule.satisfy, pre)
    }

    fn eval(&self, expr: &Satisfy, pre: &Precondition) -> bool {
        match expr {
            Satisfy::HasSetFact => self.set_facts.contains(&(pre.field.clone(), pre.value.clone())),
            Satisfy::AppendCountAtLeast => self.append_count(&pre.field) >= pre.count.max(0) as usize,
            Satisfy::SetFactInt(cmp) => self.set_facts.iter().any(|(k, v)| {
                k == &pre.field && v.parse::<i64>().map(|x| cmp.apply(x, pre.count)).unwrap_or(false)
            }),
            Satisfy::Incremented => self.incremented_fields.contains(&pre.field),
            Satisfy::SetFactNonInt => self
                .set_facts
                .iter()
                .any(|(k, v)| k == &pre.field && v.parse::<i64>().is_err()),
            Satisfy::Always => true,
            Satisfy::Never => false,
            Satisfy::And(a, b) => self.eval(a, pre) && self.eval(b, pre),
            Satisfy::Or(a, b) => self.eval(a, pre) || self.eval(b, pre),
            Satisfy::Not(a) => !self.eval(a, pre),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conception_kernel::grammar::{rule_for, Kind};

    fn pre(kind: Kind, field: &str, n: i64) -> Precondition {
        Precondition { kind, field: field.into(), count: n, target: 0, value: String::new() }
    }

    #[test]
    fn greater_than_via_set_fact() {
        let mut p = ProducedState::default();
        p.set_facts.insert(("level".into(), "5".into()));
        // 5 > 3 satisfies; 5 > 5 does not.
        assert!(p.satisfies(&pre(Kind::GreaterThan, "level", 3), &rule_for(Kind::GreaterThan)));
        assert!(!p.satisfies(&pre(Kind::GreaterThan, "level", 5), &rule_for(Kind::GreaterThan)));
    }

    #[test]
    fn greater_than_via_increment_unless_reset() {
        let mut p = ProducedState::default();
        p.incremented_fields.insert("level".into());
        // incremented and no reset → satisfied for > 0.
        assert!(p.satisfies(&pre(Kind::GreaterThan, "level", 0), &rule_for(Kind::GreaterThan)));
        // a set that reset it to <= n cancels the increment branch.
        p.set_facts.insert(("level".into(), "0".into()));
        assert!(!p.satisfies(&pre(Kind::GreaterThan, "level", 0), &rule_for(Kind::GreaterThan)));
    }

    #[test]
    fn greater_than_increment_cancelled_by_non_int_set() {
        // generator's reset-guard uses unwrap_or(true): a non-integer set-fact
        // on the field trips the guard and kills the increment branch. Without
        // the SetFactNonInt atom the kernel would wrongly report satisfied.
        let mut p = ProducedState::default();
        p.incremented_fields.insert("score".into());
        p.set_facts.insert(("score".into(), "reset".into())); // non-int
        assert!(!p.satisfies(&pre(Kind::GreaterThan, "score", 0), &rule_for(Kind::GreaterThan)));
    }

    #[test]
    fn greater_or_equal_boundary() {
        let mut p = ProducedState::default();
        p.set_facts.insert(("n".into(), "3".into()));
        assert!(p.satisfies(&pre(Kind::GreaterOrEqual, "n", 3), &rule_for(Kind::GreaterOrEqual)));
        assert!(!p.satisfies(&pre(Kind::GreaterOrEqual, "n", 4), &rule_for(Kind::GreaterOrEqual)));
    }

    #[test]
    fn less_than_never_satisfied_by_chain() {
        let mut p = ProducedState::default();
        p.set_facts.insert(("n".into(), "0".into()));
        assert!(!p.satisfies(&pre(Kind::LessThan, "n", 5), &rule_for(Kind::LessThan)));
    }
}
