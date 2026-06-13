//! conception_kernel::produced_state — the facts a setup chain has produced.
//!
//! Threaded through the planner's recursion so a later precondition already
//! covered by an earlier step is skipped, and so an Append loop subtracts
//! existing instances (a MinSizeList chain doesn't double-seed). `satisfies`
//! dispatches on the rule's GENERAL `SatisfyPrimitive` — never on the kind.
//!
//! First slice records `Set` and `Append` effects. Lifecycle-transition facts
//! and integer (`Increment`) effects arrive with their kinds in later slices.
//!
//! Example:
//!   let mut p = ProducedState::default();
//!   p.absorb(add_item_cmd);            // one Append on `items`
//!   assert_eq!(p.append_count("items"), 1);

use crate::ir::{Command, MutationOp};
use std::collections::{BTreeMap, BTreeSet};

use super::grammar::{KindRule, Precondition, SatisfyPrimitive};

#[derive(Default)]
pub struct ProducedState {
    /// `(field, value)` pairs from `Set` mutations.
    set_facts: BTreeSet<(String, String)>,
    /// Per-field count of `Append` mutations across chain steps.
    append_counts: BTreeMap<String, usize>,
}

impl ProducedState {
    /// Record a chain step's direct effects.
    pub fn absorb(&mut self, cmd: &Command) {
        for m in &cmd.mutations {
            match m.operation {
                MutationOp::Set => {
                    self.set_facts
                        .insert((m.field.clone(), m.value.trim_matches('"').to_string()));
                }
                MutationOp::Append => {
                    *self.append_counts.entry(m.field.clone()).or_insert(0) += 1;
                }
                _ => {}
            }
        }
    }

    pub fn append_count(&self, field: &str) -> usize {
        self.append_counts.get(field).copied().unwrap_or(0)
    }

    /// True when produced facts already satisfy `pre`, via the rule's primitive.
    pub fn satisfies(&self, pre: &Precondition, rule: &KindRule) -> bool {
        match rule.satisfy {
            SatisfyPrimitive::HasSetFact => {
                self.set_facts.contains(&(pre.field.clone(), pre.value.clone()))
            }
            SatisfyPrimitive::AppendCountAtLeast => {
                self.append_count(&pre.field) >= pre.count.max(0) as usize
            }
            SatisfyPrimitive::Always => true,
        }
    }
}
