//! Lifecycle validator
//!
//! Catches contradictions in lifecycle declarations — patterns where
//! a transition is structurally unreachable from any state the
//! aggregate can actually be in.
//!
//! The most common bug this catches:
//!
//!   attribute :status, default: "active"
//!   lifecycle :status do
//!     transition "OpenRecord" => "active", from: "none"
//!   end
//!
//! New aggregates start with `status = "active"` (the default).
//! `OpenRecord` requires `from: "none"`. Nothing transitions to "none".
//! Therefore OpenRecord can never fire. The bluebook is contradictory.
//!
//! Two checks:
//!
//! 1. **Unreachable from_state.** A transition's `from:` value must be
//!    either the lifecycle default OR the to_state of some other
//!    transition. Otherwise the transition is dead.
//!
//! 2. **Stuck default.** If the lifecycle has transitions but none of
//!    them can fire from the default state, the aggregate is stuck
//!    in default forever. Warning.
//!
//! Surface:
//!
//!   hecks-life check-lifecycle path/to/bluebook.bluebook
//!   hecks-life check-lifecycle path/to/bluebook.bluebook --strict
//!
//! Exit code:
//!   0 — no errors (and no warnings if --strict isn't set)
//!   1 — at least one error, or --strict and at least one warning

use crate::ir::{Aggregate, Domain, Lifecycle};
use std::collections::BTreeSet;

#[derive(Debug, PartialEq)]
pub enum Severity { Error, Warning }

pub struct Finding {
    pub severity: Severity,
    pub location: String,
    pub message: String,
}

impl Finding {
    fn err(location: impl Into<String>, message: impl Into<String>) -> Self {
        Finding { severity: Severity::Error, location: location.into(), message: message.into() }
    }
    fn warn(location: impl Into<String>, message: impl Into<String>) -> Self {
        Finding { severity: Severity::Warning, location: location.into(), message: message.into() }
    }
    pub fn icon(&self) -> &'static str {
        match self.severity { Severity::Error => "✗", Severity::Warning => "⚠" }
    }
}

pub struct Report {
    pub findings: Vec<Finding>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Error).count()
    }
    pub fn warnings(&self) -> usize {
        self.findings.iter().filter(|f| f.severity == Severity::Warning).count()
    }
    pub fn passes(&self, strict: bool) -> bool {
        if self.errors() > 0 { return false; }
        if strict && self.warnings() > 0 { return false; }
        true
    }
}

pub fn check(domain: &Domain) -> Report {
    let mut findings = Vec::new();
    for agg in &domain.aggregates {
        if let Some(lc) = &agg.lifecycle {
            check_aggregate(agg, lc, &mut findings);
        }
    }
    Report { findings }
}

fn check_aggregate(agg: &Aggregate, lc: &Lifecycle, out: &mut Vec<Finding>) {
    // Reachable states: the lifecycle default plus every transition's
    // to_state. Anything outside this set is unreachable, so a
    // transition with `from:` pointing outside it is dead code.
    let mut reachable: BTreeSet<String> = BTreeSet::new();
    if !lc.default.is_empty() {
        reachable.insert(lc.default.clone());
    }
    for t in &lc.transitions {
        reachable.insert(t.to_state.clone());
    }

    for t in &lc.transitions {
        if let Some(from) = &t.from_state {
            if !reachable.contains(from) {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, t.command),
                    format!(
                        "transition's from: {:?} is unreachable — \
                         the {:?} field can only be {} \
                         (default {:?} + transition to_states), so this \
                         transition can never fire",
                        from, lc.field,
                        format_set(&reachable),
                        lc.default,
                    ),
                ));
            }
        }
    }

    // Stuck-default warning: if the lifecycle has transitions but none
    // can fire when the field is at its default value, the aggregate
    // is permanently stuck in default. (Transitions with from_state =
    // None fire from any state including default.)
    if !lc.transitions.is_empty() {
        let any_fires_from_default = lc.transitions.iter().any(|t| match &t.from_state {
            None => true,
            Some(from) => from == &lc.default,
        });
        if !any_fires_from_default {
            out.push(Finding::warn(
                format!("{}.lifecycle({})", agg.name, lc.field),
                format!(
                    "no transition can fire from the default state {:?} — \
                     fresh aggregates will be stuck forever",
                    lc.default,
                ),
            ));
        }
    }
}

fn format_set(set: &BTreeSet<String>) -> String {
    let v: Vec<String> = set.iter().map(|s| format!("{:?}", s)).collect();
    if v.is_empty() { "{}".into() } else { format!("{{{}}}", v.join(", ")) }
}
