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
            "⚠ domain '{}' has {} aggregates ; review for cohesion (sweet spot is 3-6 ; past 7 most domains read as two)",
            domain.name,
            domain.aggregates.len()
        ))
    } else {
        None
    }
}

/// Returns Some(msg) if the domain has more than 11 aggregates.
pub fn multi_domain_split_warning(domain: &Domain) -> Option<String> {
    if domain.aggregates.len() > 11 {
        Some(format!(
            "⚠ domain '{}' has {} aggregates ; multi-domain split likely improves cohesion (two ubiquitous languages are usually being merged at this size)",
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
/// Returns Some(msg) if the domain has 50+ aggregates split across
/// disconnected reference/policy clusters.
pub fn bluebook_size_warning(domain: &Domain) -> Option<String> {
    let mut units = domain.aggregates.len();
    for agg in &domain.aggregates {
        units += agg.attributes.len();
        units += agg.commands.len();
        for cmd in &agg.commands {
            units += cmd.attributes.len();
        }
        if let Some(lc) = &agg.lifecycle {
            units += lc.transitions.len();
        }
    }
    units += domain.policies.len();
    if units > 50 {
        Some(format!(
            "⚠ bluebook '{}' has {} structural units (aggregates + attributes + commands + policies + transitions) — is this really one concern, or is it two ?",
            domain.name, units
        ))
    } else {
        None
    }
}

/// Flags aggregates that have a `lifecycle` block OR a self-referencing
/// `reference_to` (a command pointing back to its own aggregate) but
/// declare no `identified_by`. Without `identified_by`, the in-memory
/// runner counter-mints a fresh u64 id on every dispatch — the lifecycle
/// state never advances past `pending`, and the self-ref form (used by
/// transition commands) targets a fresh record each time.
///
/// Skipped when the aggregate has `identified_by` already, or when it
/// has neither a lifecycle nor a self-ref (event-log style stores
/// legitimately want counter-mint behavior).
///
/// Per-bluebook check — no corpus context required. Returns one warning
/// per offending aggregate.
pub fn identified_by_warnings(domain: &Domain) -> Vec<String> {
    let mut warnings = vec![];
    for agg in &domain.aggregates {
        if agg.identified_by.is_some() {
            continue;
        }
        let has_lifecycle = agg.lifecycle.is_some();
        let has_self_ref = agg.commands.iter().any(|cmd| {
            cmd.references.iter().any(|r| r.target == agg.name && r.domain.is_none())
        });
        if !has_lifecycle && !has_self_ref {
            continue;
        }
        warnings.push(format!(
            "⚠ aggregate '{}' has a {} but no identified_by — consider 'identified_by :name' so the in-memory runner converges on a single record",
            agg.name,
            if has_lifecycle { "lifecycle" } else { "self-referencing command" }
        ));
    }
    warnings
}

/// Corpus-wide check: flags policies whose `on_event` is emitted by no
/// command anywhere in the merged Domain. The policy is dangling — it
/// will never fire. This is advisory, not blocking : an event with no
/// current emitter could be intentional (placeholder for a future
/// bluebook).
///
/// Companion to the existing `valid_policy_triggers` rule in validator.rs
/// (which flags missing trigger commands as INVALID). The two functions
/// together catch both ends of the policy/event coherence problem when
/// the Domain has been merged across the corpus.
///
/// When called on a single-file Domain (no corpus merge) the function
/// returns no findings — flagging on a partial Domain would produce
/// false positives for cross-bluebook event flow.
pub fn policy_event_warnings(domain: &Domain) -> Vec<String> {
    // Single-file heuristic : if the Domain has fewer than 2 aggregates
    // OR no policies cross aggregate names, we lack the corpus context
    // to make corpus-wide claims. Skip silently.
    if domain.policies.is_empty() || domain.aggregates.len() < 2 {
        return vec![];
    }

    let mut emitted: HashSet<&str> = HashSet::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if let Some(ref e) = cmd.emits {
                emitted.insert(e.as_str());
            }
        }
    }

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none())
        .filter(|p| !emitted.contains(p.on_event.as_str()))
        .map(|p| {
            format!(
                "⚠ policy '{}' subscribes to event '{}' that no command emits in the corpus — placeholder for future bluebook, or a typo ?",
                p.name, p.on_event
            )
        })
        .collect()
}
