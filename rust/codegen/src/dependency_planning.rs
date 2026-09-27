//! Port of `rust/project/dependency_planning.rb`, an independent re-derivation of the
//! Analyzer's `complete_state? && state_independent?` predicate. Mirrors the Ruby file.

use crate::json::Json;
use crate::literal::{self, Literal};
use std::collections::{HashMap, HashSet};

/// True when every owner field of a creating command is written from known values.
///
/// The router uses it alone to decide whether a route is checked against derived identity.
pub fn complete_state_creation(aggregate: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    let owner_fields = owner_fields(aggregate);
    let payload_fields: HashSet<String> = command.get("attributes").map(Json::each).unwrap_or(&[]).iter().map(|a| crate::attr::name(a).to_string()).collect();

    let (known_writes, disqualified) = known_writes(aggregate, command, &owner_fields, &payload_fields, value_objects_by_name);
    !disqualified && owner_fields.iter().all(|field| known_writes.contains(field))
}

/// True when a creating command's result does not depend on prior state.
///
/// Only meaningful for a command `crate::shared::creates_owner` answered `true` for.
pub fn state_independent_creation(aggregate: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    if !complete_state_creation(aggregate, command, value_objects_by_name) {
        return false;
    }
    let owner_fields = owner_fields(aggregate);
    let payload_fields: HashSet<String> = command.get("attributes").map(Json::each).unwrap_or(&[]).iter().map(|a| crate::attr::name(a).to_string()).collect();

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

fn classify_symbol(name: &str, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> Classification {
    if payload_fields.contains(name) {
        Classification::Known
    } else if owner_fields.contains(name) {
        Classification::StateRead
    } else {
        Classification::Unresolved
    }
}

// A `StateRef` source falls through to `Known`, matching the Ruby Analyzer, which has no
// `when StateRef` branch.
fn classify_source(source: &Json, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> Classification {
    match source.get("kind").map(Json::to_s).as_deref() {
        Some("argument") => classify_symbol(&source.get("name").map(Json::to_s).unwrap_or_default(), payload_fields, owner_fields),
        _ => Classification::Known,
    }
}

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

    // A creating command guarded by a lifecycle `from:` state has no prior state to check.
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
                // Stateful: never contributes to `known_writes`.
            }
            _ => disqualified = true,
        }
    }

    (known, disqualified)
}

fn deterministic_initial_value(attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    if crate::attr::list(attr) || crate::attr::optional(attr) || crate::attr::default(attr).is_some() {
        return true;
    }

    match value_objects_by_name.get(crate::attr::type_name(attr)) {
        Some(vo) => vo.get("attributes").map(Json::each).unwrap_or(&[]).iter().all(|field| crate::attr::default(field).is_some()),
        None => false,
    }
}

// `before` is true for a `given`, false for an `ensures` or invariant.
fn rule_state_independent(ast: &Json, before: bool, payload_fields: &HashSet<String>, owner_fields: &HashSet<String>) -> bool {
    paths(ast, &HashSet::new()).iter().all(|path| path_state_independent(path, before, payload_fields, owner_fields))
}

// Only `lookup` and `block_predicate` nodes are special-cased; the rest recurse.
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
