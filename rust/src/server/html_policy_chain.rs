//! PolicyChain — trace downstream cascades through policies
//!
//! Mirrors the PolicyChain aggregate from DomainNarration bluebook.
//! Follows: command → emits event → policy listens → triggers command → ...
//!
//! Usage:
//!   let chain = trace_chain("CalculateTotals", &domain);

use crate::ir::Domain;
use std::collections::HashSet;

/// Trace what a triggered command emits, and if any policy listens.
/// Returns chain of (event, next_command) pairs for downstream visualization.
pub fn trace_chain(command_name: &str, domain: &Domain) -> Vec<(String, String)> {
    let mut chain = Vec::new();
    let mut seen = HashSet::new();
    let mut current = command_name.to_string();

    // Walk the chain: command → emits event → policy listens → triggers command
    for _ in 0..10 {
        if seen.contains(&current) { break; }
        seen.insert(current.clone());

        let emitted = domain.aggregates.iter()
            .flat_map(|a| &a.commands)
            .find(|c| c.name == current)
            .and_then(|c| c.emits.as_ref());

        let event = match emitted {
            Some(e) => e.clone(),
            None => break,
        };

        let next = domain.policies.iter()
            .find(|p| p.on_event == event)
            .map(|p| p.trigger_command.clone());

        match next {
            Some(cmd) => {
                chain.push((event, cmd.clone()));
                current = cmd;
            }
            None => break,
        }
    }

    chain
}
