//! Rules — extract preconditions and invariants from command givens
//!
//! Mirrors the Rule aggregate from DomainNarration bluebook.
//! Walks every command's givens and surfaces them as human-readable rules.
//!
//! Usage:
//!   let rules = collect_invariants(&domain);

use crate::ir::Domain;

/// Collect invariants/preconditions from command givens.
/// Returns (command_name, rule_text) pairs.
pub fn collect_invariants(domain: &Domain) -> Vec<(String, String)> {
    let mut invariants = Vec::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            for g in &cmd.givens {
                let text = g.message.as_deref()
                    .unwrap_or(&g.expression);
                invariants.push((cmd.name.clone(), text.to_string()));
            }
        }
    }
    invariants
}
