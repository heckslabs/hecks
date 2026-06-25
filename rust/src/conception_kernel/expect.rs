//! conception_kernel::expect — the expected-state assertion builder, plan-independent.
//!
//! `build_expect` predicts the aggregate state after one command runs, as a
//! `[(field, value)]` list the conceived test asserts against. It reads a single
//! command's IR (create-style attrs, direct mutations, lifecycle transition) plus
//! the kernel's `SampleValueRule` table — it does NOT depend on the setup-chain
//! PLAN — so it moves into the kernel ahead of the planner switch. The three small
//! token helpers it composes (`is_create_command`, `quote_string`,
//! `resolve_mutation_value`) move with it as one unit. `generator.rs` delegates to
//! all four until it is deleted at the final gate.
//!
//! Usage:
//!   let pairs = conception_kernel::expect::build_expect(domain, agg, cmd, None);
//!   // [("status", "\"open\""), ("items_size", "1")]

use crate::conception_kernel::sample::sample_value;
use crate::ir::{Aggregate, Command, Domain, MutationOp};
use std::collections::BTreeSet;

/// Wrap a bare string token in quotes so it parses as a string in
/// the behaviors DSL (which extracts via extract_string).
pub fn quote_string(s: &str) -> String {
    format!("{:?}", s)
}

/// True when the command's name carries a create-style prefix — the runtime
/// auto-bootstraps matching command attrs onto the new aggregate's state.
pub fn is_create_command(cmd: &Command) -> bool {
    for prefix in &["Create", "Add", "Place", "Register", "Open"] {
        if cmd.name.starts_with(prefix) {
            return true;
        }
    }
    false
}

/// Resolve a mutation's source-token value into the sample value the
/// runtime would actually store. Strings/numbers come through as-is;
/// `:symbol` is treated as a reference to either a command attribute
/// (resolved to its sample value) or a command reference (resolved to
/// the cross-ref id "1" — same id the synthesized input passes).
pub fn resolve_mutation_value(raw: &str, cmd: &Command) -> String {
    let trimmed = raw.trim();
    if let Some(name) = trimmed.strip_prefix(':') {
        if let Some(attr) = cmd.attributes.iter().find(|a| a.name == name) {
            return sample_value(&attr.attr_type);
        }
        // Reference (cross-ref or self-ref): synthesized input passes
        // "1" for every reference; the runtime stores that id on the
        // aggregate's <ref_name> field.
        if cmd.references.iter().any(|r| r.name == name) {
            return "1".into();
        }
    }
    raw.to_string()
}

/// Predict the aggregate state after `cmd` runs, merged from three sources:
///   1. Create-style: command attrs that also appear as aggregate attrs.
///   2. Direct `then_set` / append / toggle mutations on the command.
///   3. A direct lifecycle transition the command drives.
/// The cascade lockdown lives in a SEPARATE `kind: :cascade` test, not here —
/// mixing it in causes per-field overshoot. `_domain` / `_lifecycle_to` are part
/// of the verbatim signature and unused today.
pub fn build_expect(
    _domain: &Domain,
    agg: &Aggregate,
    cmd: &Command,
    _lifecycle_to: Option<(String, String)>,
) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();

    let agg_attr_names: BTreeSet<&str> = agg.attributes.iter().map(|a| a.name.as_str()).collect();

    // 1. Create-style: runtime copies matching cmd attrs to aggregate state.
    if is_create_command(cmd) {
        for attr in &cmd.attributes {
            if agg_attr_names.contains(attr.name.as_str()) && seen.insert(attr.name.clone()) {
                out.push((attr.name.clone(), sample_value(&attr.attr_type)));
            }
        }
        // Lifecycle default: only emit if the create command itself has
        // no transition (otherwise the transition below adds the to_state,
        // which is more specific).
        if let Some(lc) = &agg.lifecycle {
            let has_transition = lc.transitions.iter().any(|t| t.command == cmd.name);
            if !has_transition && !lc.default.is_empty() && seen.insert(lc.field.clone()) {
                out.push((lc.field.clone(), quote_string(&lc.default)));
            }
        }
    }

    // 2. Direct mutations on `cmd` (no cascade simulation — the cascade
    //    is locked down via `emits:` instead).
    for m in &cmd.mutations {
        match m.operation {
            MutationOp::Set => {
                let value = resolve_mutation_value(&m.value, cmd);
                out.retain(|(k, _)| k != &m.field);
                out.push((m.field.clone(), value));
                seen.insert(m.field.clone());
            }
            MutationOp::Append => {
                let key = format!("{}_size", m.field);
                if seen.insert(key.clone()) {
                    out.push((key, "1".into()));
                }
            }
            MutationOp::Toggle => {
                if seen.insert(m.field.clone()) {
                    out.push((m.field.clone(), "true".into()));
                }
            }
            // Increment/Decrement depend on prior state — skip prediction.
            _ => {}
        }
    }

    // 3. Direct lifecycle transition for `cmd`.
    if let Some(lc) = &agg.lifecycle {
        if let Some(t) = lc.transitions.iter().find(|t| t.command == cmd.name) {
            out.retain(|(k, _)| k != &lc.field);
            out.push((lc.field.clone(), quote_string(&t.to_state)));
            seen.insert(lc.field.clone());
        }
    }

    // The cascade lockdown lives in a SEPARATE test (kind: :cascade) —
    // see emit_cascade_test. Mixing it into the state assertion causes
    // overshoot: the state has cascaded past the command's direct
    // mutations, so per-field assertions fail. The split keeps each
    // test single-purpose.

    if out.is_empty() {
        out.push(("ok".into(), "\"true\"".into()));
    }
    out
}
