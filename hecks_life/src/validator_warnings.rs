//! Soft warnings for domain quality — non-failing checks
//!
//! These rules emit warnings but never cause validation to fail.
//! They help domain modelers spot bounded-context smell early.
//!
//! Usage:
//!   let warns = validator_warnings::warnings(&domain);
//!   for w in &warns { println!("  WARNING: {}", w); }

use crate::ir::Domain;
use std::collections::{HashMap, HashSet, VecDeque};

/// Run all warning rules and return collected warnings.
pub fn warnings(domain: &Domain) -> Vec<String> {
    let mut warns = vec![];
    warns.extend(aggregate_count_warning(domain));
    warns.extend(mixed_concerns_warning(domain));
    warns
}

/// Warn if a domain has more than 7 aggregates — it may need splitting.
fn aggregate_count_warning(domain: &Domain) -> Vec<String> {
    let count = domain.aggregates.len();
    if count > 7 {
        vec![format!(
            "Domain {} has {} aggregates — consider splitting into bounded contexts",
            domain.name, count
        )]
    } else {
        vec![]
    }
}

/// Warn if aggregates form a disconnected graph (only for 5+ aggregates).
///
/// Two aggregates are "connected" if one references the other via
/// reference_to, or they share a policy (event from one triggers
/// command in the other). Disconnected clusters suggest separate
/// bounded contexts.
fn mixed_concerns_warning(domain: &Domain) -> Vec<String> {
    let count = domain.aggregates.len();
    if count < 5 {
        return vec![];
    }

    let agg_names: Vec<&str> = domain.aggregates.iter().map(|a| a.name.as_str()).collect();
    let mut adj: HashMap<&str, HashSet<&str>> = HashMap::new();
    for name in &agg_names {
        adj.insert(name, HashSet::new());
    }

    // Build event->aggregate and command->aggregate maps
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

    // Connect via within-domain policies
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

    // Connect via cross-aggregate references
    let agg_set: HashSet<&str> = agg_names.iter().copied().collect();
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if reference.domain.is_none() && agg_set.contains(reference.target.as_str()) {
                adj.get_mut(agg.name.as_str()).map(|s| s.insert(reference.target.as_str()));
                adj.get_mut(reference.target.as_str()).map(|s| s.insert(agg.name.as_str()));
            }
        }
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if reference.domain.is_none()
                    && agg_set.contains(reference.target.as_str())
                    && reference.target != agg.name
                {
                    adj.get_mut(agg.name.as_str()).map(|s| s.insert(reference.target.as_str()));
                    adj.get_mut(reference.target.as_str()).map(|s| s.insert(agg.name.as_str()));
                }
            }
        }
    }

    // BFS to find connected components
    let mut visited: HashSet<&str> = HashSet::new();
    let mut components: Vec<Vec<&str>> = vec![];
    for name in &agg_names {
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
        return vec![];
    }

    let mut warns = vec![];
    for i in 0..components.len() {
        for j in (i + 1)..components.len() {
            let a = components[i][0];
            let b = components[j][0];
            warns.push(format!(
                "Aggregates {} and {} have no references between them — they may belong in separate bounded contexts",
                a, b
            ));
        }
    }
    warns
}
