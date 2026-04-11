//! Evolve — graft new aggregates onto an existing domain
//!
//! Reads a target bluebook and a source domain, finds aggregates
//! in the source that match the requested feature keyword, and
//! grafts them into the target with a version bump.
//!
//! Usage:
//!   let text = evolve_bluebook(&target, &source, "audit logging");

use crate::ir::{Domain, Aggregate};
use super::generator::emit_aggregate;

/// Evolve an existing domain by grafting aggregates from a source.
pub fn evolve_bluebook(target: &Domain, source: &Domain, feature: &str) -> String {
    let existing_names: Vec<&str> = target.aggregates.iter().map(|a| a.name.as_str()).collect();

    let new_aggs: Vec<&Aggregate> = source
        .aggregates
        .iter()
        .filter(|a| !existing_names.contains(&a.name.as_str()))
        .filter(|a| matches_feature(a, feature))
        .collect();

    let version = bump_version();
    let mut out = Vec::new();
    out.push(format!(
        "Hecks.bluebook \"{}\", version: \"{}\" do",
        target.name, version
    ));

    for agg in &target.aggregates {
        emit_aggregate(&mut out, agg, &target.name);
        out.push(String::new());
    }

    if !new_aggs.is_empty() {
        out.push(format!("  # === Grafted from {} ({}) ===", source.name, feature));
        out.push(String::new());
        for agg in &new_aggs {
            emit_aggregate(&mut out, agg, &target.name);
            out.push(String::new());
        }
    }

    for pol in &target.policies {
        out.push(format!("  policy \"{}\" do", pol.name));
        out.push(format!("    on \"{}\"", pol.on_event));
        out.push(format!("    trigger \"{}\"", pol.trigger_command));
        out.push("  end".into());
    }

    if out.last().map(|l| l.is_empty()).unwrap_or(false) {
        out.pop();
    }
    out.push("end".into());
    out.join("\n")
}

fn matches_feature(agg: &Aggregate, feature: &str) -> bool {
    let kw: Vec<&str> = feature.split_whitespace().collect();
    let haystack = format!(
        "{} {} {}",
        agg.name.to_lowercase(),
        agg.description.as_deref().unwrap_or("").to_lowercase(),
        agg.commands.iter().map(|c| c.name.to_lowercase()).collect::<Vec<_>>().join(" ")
    );
    kw.iter().any(|k| haystack.contains(&k.to_lowercase()))
}

fn bump_version() -> String {
    format!("2026.04.11.2")
}
