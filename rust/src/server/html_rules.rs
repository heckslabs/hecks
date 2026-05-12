//! Rules — extract preconditions and invariants from command givens
//!
//! Mirrors the Rule aggregate from DomainNarration bluebook.
//! Walks every command's givens and surfaces them as human-readable rules.
//!
//! Usage:
//!   let rules = collect_invariants(&domain);
//!   let agg_rules = collect_invariants_for(&aggregate);

use crate::ir::{Aggregate, Domain};

/// Collect invariants/preconditions from command givens.
/// Returns (command_name, rule_text) pairs.
pub fn collect_invariants(domain: &Domain) -> Vec<(String, String)> {
    let mut invariants = Vec::new();
    for agg in &domain.aggregates {
        invariants.extend(collect_invariants_for(agg));
    }
    invariants
}

/// Collect invariants/preconditions for one aggregate only.
/// Used by per-card rules sections (i113) so the operator sees the
/// rules that govern *this* aggregate's commands, not a flat dump of
/// every rule in the domain.
pub fn collect_invariants_for(agg: &Aggregate) -> Vec<(String, String)> {
    let mut invariants = Vec::new();
    for cmd in &agg.commands {
        for g in &cmd.givens {
            let text = g.message.as_deref()
                .unwrap_or(&g.expression);
            invariants.push((cmd.name.clone(), text.to_string()));
        }
    }
    invariants
}
