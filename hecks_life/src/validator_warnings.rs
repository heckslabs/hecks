//! Soft warnings for domain quality — non-failing bounded-context checks
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/validator_warnings_shape/
//! Regenerate: hecks-life specialize validator_warnings --output hecks_life/src/validator_warnings.rs
//! Contract:  hecks_life/src/specializer/validator_warnings.rs (Rust-native)
//! Tests:     hecks_life/tests/validator_warnings_test.rs
//!
//! These rules emit advisory warnings but never cause validation to fail.
//! They help domain modelers spot bounded-context smell early.
//!
//! Usage:
//!   if let Some(msg) = validator_warnings::aggregate_count_warning(&domain) {
//!       println!("  {}", msg);
//!   }
//!   if let Some(msg) = validator_warnings::mixed_concerns_warning(&domain) {
//!       println!("  {}", msg);
//!   }

use crate::ir::Domain;
use std::collections::{HashMap, HashSet, VecDeque};

/// Returns Some(msg) if the domain has more than 7 aggregates.
pub fn aggregate_count_warning(domain: &Domain) -> Option<String> {
    if domain.aggregates.len() > 7 {
        Some(format!(
            "⚠ domain '{}' has {} aggregates; consider splitting",
            domain.name,
            domain.aggregates.len()
        ))
    } else {
        None
    }
}

/// Returns Some(msg) if the domain has 5+ aggregates split across
/// disconnected reference/policy clusters.
pub fn mixed_concerns_warning(domain: &Domain) -> Option<String> {
    if domain.aggregates.len() < 5 {
        return None;
    }

    let names: Vec<&str> = domain.aggregates.iter().map(|a| a.name.as_str()).collect();
    let name_set: HashSet<&str> = names.iter().copied().collect();

    // adjacency: aggregate name -> set of neighbor names
    let mut adj: HashMap<&str, HashSet<&str>> = HashMap::new();
    for name in &names {
        adj.insert(name, HashSet::new());
    }

    // Edges from reference_to on aggregate attributes (Reference)
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if reference.domain.is_none() && name_set.contains(reference.target.as_str()) {
                let a = agg.name.as_str();
                let b = reference.target.as_str();
                if a != b {
                    adj.get_mut(a).map(|s| s.insert(b));
                    adj.get_mut(b).map(|s| s.insert(a));
                }
            }
        }
        // Edges from reference_to on command parameters
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if reference.domain.is_none() && name_set.contains(reference.target.as_str()) {
                    let a = agg.name.as_str();
                    let b = reference.target.as_str();
                    if a != b {
                        adj.get_mut(a).map(|s| s.insert(b));
                        adj.get_mut(b).map(|s| s.insert(a));
                    }
                }
            }
        }
    }

    // Build event->aggregate and command->aggregate maps for policy edges
    let mut event_to_agg: HashMap<&str, &str> = HashMap::new();
    let mut cmd_to_agg: HashMap<&str, &str> = HashMap::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            cmd_to_agg.insert(cmd.name.as_str(), agg.name.as_str());
            if let Some(ref event) = cmd.emits {
                event_to_agg.insert(event.as_str(), agg.name.as_str());
            }
        }
    }
    // Edges from within-domain policies (a policy on A triggers a command on B)
    for policy in &domain.policies {
        if policy.target_domain.is_some() {
            continue;
        }
        let from = event_to_agg.get(policy.on_event.as_str());
        let to = cmd_to_agg.get(policy.trigger_command.as_str());
        if let (Some(&f), Some(&t)) = (from, to) {
            if f != t {
                adj.get_mut(f).map(|s| s.insert(t));
                adj.get_mut(t).map(|s| s.insert(f));
            }
        }
    }

    // BFS to find connected components
    let mut visited: HashSet<&str> = HashSet::new();
    let mut components: Vec<Vec<&str>> = vec![];
    for name in &names {
        if visited.contains(name) {
            continue;
        }
        let mut component = vec![];
        let mut queue = VecDeque::new();
        queue.push_back(*name);
        visited.insert(name);
        while let Some(current) = queue.pop_front() {
            component.push(current);
            if let Some(neighbors) = adj.get(current) {
                for &neighbor in neighbors {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor);
                        queue.push_back(neighbor);
                    }
                }
            }
        }
        components.push(component);
    }

    if components.len() <= 1 {
        return None;
    }

    let rendered: Vec<String> = components
        .iter()
        .map(|c| format!("[{}]", c.join(",")))
        .collect();

    Some(format!(
        "⚠ domain '{}' has {} disconnected concern clusters: {}",
        domain.name,
        components.len(),
        rendered.join(" and ")
    ))
}
