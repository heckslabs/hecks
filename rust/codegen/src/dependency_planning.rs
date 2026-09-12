//! Port of `rust/project/dependency_planning.rb` — read that file's own
//! header in full for why this is a SEPARATE, independent re-derivation
//! (never a shared field ferried through ir.json) of `Runtime::
//! DependencyPlanning::Analyzer#call`'s `complete_state? &&
//! state_independent?` predicate, and why that's the right shape for
//! BUG#28 (QualityControl ledger) rather than the more obvious-looking
//! "compute it once in Ruby, read a bool here" alternative.
//!
//! Mirrors the Ruby file function-for-function so the two stay directly
//! diffable; `spec/codegen_parity_spec.rb`'s existing whole-file
//! byte-identity check is what proves they agree.

use crate::json::Json;
use crate::literal::{self, Literal};
use std::collections::{HashMap, HashSet};

/// `state_independent_creation?` — see the Ruby file's own header.
/// ONLY MEANINGFUL for a command `crate::shared::creates_owner` already
/// answered `true` for. `value_objects_by_name` — the SAME domain-wide
/// map `emit_command`'s own caller already built, reused rather than
/// rebuilt.
pub fn state_independent_creation(aggregate: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    let owner_fields = owner_fields(aggregate);
    let payload_fields: HashSet<String> = command.get("attributes").map(Json::each).unwrap_or(&[]).iter().map(|a| crate::attr::name(a).to_string()).collect();

    let (known_writes, disqualified) = known_writes(aggregate, command, &owner_fields, &payload_fields, value_objects_by_name);
    if disqualified {
        return false;
    }
    if !owner_fields.iter().all(|field| known_writes.contains(field)) {
        return false;
    }

    let mut rules: Vec<(&Json, bool)> = Vec::new();
    for rule in command.get("givens").map(Json::each).unwrap_or(&[]) {
        rules.push((rule, true)); // `true` == "before" (a given)
    }
    for rule in command.get("ensures").map(Json::each).unwrap_or(&[]) {
        rules.push((rule, false));
    }
    for rule in aggregate.get("invariants").map(Json::each).unwrap_or(&[]) {
        rules.push((rule, false));
    }

    rules.iter().all(|(rule, before)| {
        let ast = rule.get("ast").unwrap_or(&Json::Null);
        rule_state_independent(ast, *before, &payload_fields, &owner_fields)
    })
}

/// `creation_owner_fields`, ported directly.
fn owner_fields(aggregate: &Json) -> HashSet<String> {
    let mut fields: HashSet<String> = aggregate.get("attributes").map(Json::each).unwrap_or(&[]).iter().map(|a| crate::attr::name(a).to_string()).collect();
    if let Some(lifecycle) = aggregate.get("lifecycle") {
        fields.insert(lifecycle.get("field").map(Json::to_s).unwrap_or_default());
    }
    for field in aggregate.get("projected_fields").map(Json::each).unwrap_or(&[]) {
        fields.insert(field.get("name").map(Json::to_s).unwrap_or_default());
    }
    fields
}

enum Classification {
    Known,
    StateRead,
    Unresolved,
}

/// `creation_classify_symbol`, ported directly.
fn classify_symbol(name: &str, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> Classification {
    if payload_fields.contains(name) {
        Classification::Known
    } else if owner_fields.contains(name) {
        Classification::StateRead
    } else {
        Classification::Unresolved
    }
}

/// `creation_classify_source`, ported directly — `"state"` (a `StateRef`)
/// mirrors the live Ruby Analyzer's own missing `when StateRef` branch
/// (falls to `else -> true`) FAITHFULLY, not "correctly" — see the Ruby
/// file's own comment on this exact point.
fn classify_source(source: &Json, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> Classification {
    match source.get("kind").map(Json::to_s).as_deref() {
        Some("argument") => classify_symbol(&source.get("name").map(Json::to_s).unwrap_or_default(), payload_fields, owner_fields),
        _ => Classification::Known,
    }
}

/// `creation_known_writes`, ported directly.
fn known_writes(
    aggregate: &Json,
    command: &Json,
    owner_fields: &HashSet<String>,
    payload_fields: &HashSet<String>,
    value_objects_by_name: &HashMap<String, &Json>,
) -> (HashSet<String>, bool) {
    let mut known = HashSet::new();
    for attr in aggregate.get("attributes").map(Json::each).unwrap_or(&[]) {
        if deterministic_initial_value(attr, value_objects_by_name) {
            known.insert(crate::attr::name(attr).to_string());
        }
    }
    let lifecycle_field = aggregate.get("lifecycle").map(|l| l.get("field").map(Json::to_s).unwrap_or_default());
    if let Some(field) = &lifecycle_field {
        known.insert(field.clone());
    }

    // `analyze_lifecycle`'s own `state_reads << lifecycle.field if
    // command.from` — a creating command guarded by a lifecycle `from:`
    // state has no prior state to check.
    let mut disqualified = command.get("from").is_some() && aggregate.get("lifecycle").is_some();

    for mutation in command.get("mutations").map(Json::each).unwrap_or(&[]) {
        let target = mutation.get("target").map(Json::to_s).unwrap_or_default();
        let op = mutation.get("op").map(Json::to_s).unwrap_or_default();

        if !owner_fields.contains(&target) {
            disqualified = true;
            continue;
        }

        match op.as_str() {
            "set" => {
                let source = mutation.get("source").unwrap_or(&Json::Null);
                match classify_source(source, payload_fields, owner_fields) {
                    Classification::Known => {
                        known.insert(target);
                    }
                    Classification::Unresolved => disqualified = true,
                    Classification::StateRead => {}
                }
            }
            "append" => {
                if let Some(Json::Object(pairs)) = mutation.get("fields") {
                    for (_, wire_value) in pairs {
                        let parsed = literal::read(wire_value.as_str().unwrap_or(""));
                        if let Literal::Symbol(name) = parsed {
                            if matches!(classify_symbol(&name, payload_fields, owner_fields), Classification::Unresolved) {
                                disqualified = true;
                            }
                        }
                    }
                }
            }
            "increment" | "decrement" | "multiply" | "clamp" | "remove" => {
                // STATEFUL — never contributes to `known_writes`; `target`
                // staying out of it is already enough (see the Ruby
                // file's own comment on this exact arm).
            }
            _ => disqualified = true,
        }
    }

    (known, disqualified)
}

/// `creation_deterministic_initial_value?`, ported directly.
fn deterministic_initial_value(attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    if crate::attr::list(attr) || crate::attr::optional(attr) || crate::attr::default(attr).is_some() {
        return true;
    }

    match value_objects_by_name.get(crate::attr::type_name(attr)) {
        Some(vo) => vo.get("attributes").map(Json::each).unwrap_or(&[]).iter().all(|field| crate::attr::default(field).is_some()),
        None => false,
    }
}

/// `creation_rule_state_independent?`, ported directly. `before` stands
/// in for the Ruby port's `phase == :before` (a `given`, vs an `ensures`/
/// invariant).
fn rule_state_independent(ast: &Json, before: bool, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> bool {
    paths(ast, &HashSet::new()).iter().all(|path| path_state_independent(path, before, payload_fields, owner_fields))
}

/// `creation_paths`, ported node-for-node over the same JSON `ast` shape
/// `expr_emitter.rs` already walks — see the Ruby file's own header for
/// why `"lookup"`/`"block_predicate"` are the only two special-cased
/// node kinds.
fn paths(node: &Json, bound_names: &HashSet<String>) -> Vec<String> {
    match node {
        Json::Object(pairs) => {
            let op = pairs.iter().find(|(k, _)| k == "op").map(|(_, v)| v.to_s());
            match op.as_deref() {
                Some("lookup") => {
                    let segments = pairs.iter().find(|(k, _)| k == "path").map(|(_, v)| v.each()).unwrap_or(&[]);
                    let root = segments.first().map(Json::to_s).unwrap_or_default();
                    if bound_names.contains(&root) {
                        vec![]
                    } else {
                        vec![segments.iter().map(Json::to_s).collect::<Vec<_>>().join(".")]
                    }
                }
                Some("block_predicate") => {
                    let receiver = pairs.iter().find(|(k, _)| k == "receiver").map(|(_, v)| v).unwrap_or(&Json::Null);
                    let predicate = pairs.iter().find(|(k, _)| k == "predicate").map(|(_, v)| v).unwrap_or(&Json::Null);
                    let param = pairs.iter().find(|(k, _)| k == "param").map(|(_, v)| v.to_s()).unwrap_or_default();
                    let mut bound_with_param = bound_names.clone();
                    bound_with_param.insert(param);
                    let mut found = paths(receiver, bound_names);
                    found.extend(paths(predicate, &bound_with_param));
                    found
                }
                _ => pairs.iter().flat_map(|(_, value)| paths(value, bound_names)).collect(),
            }
        }
        Json::Array(items) => items.iter().flat_map(|value| paths(value, bound_names)).collect(),
        _ => vec![],
    }
}

/// `creation_path_state_independent?`, ported directly.
fn path_state_independent(path: &str, before: bool, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> bool {
    let head = path.split('.').next().unwrap_or("");

    match head {
        "parent" | "old" => false,
        _ => {
            if payload_fields.contains(head) {
                return true;
            }
            if !owner_fields.contains(head) {
                return false;
            }
            !before
        }
    }
}
