// Port of lib/hecks/runtime/storage_shape.rb's `project`/`mint_hash`/
// `mint_label` — the canonical shape-hash Ruby computes once at mint
// time. rust/host needs to compute the SAME hash independently at boot,
// to detect drift against `hecks_eras` by comparing its own compiled
// shape rather than trusting an externally-supplied era number
// (journal.rs's own `LineageConfig` doc comment names exactly this as
// today's gap).
//
// Operates on the SAME `ir.json` `Value` `crate::ir::ir()` already
// loads generically — no new build-time export needed. `bluebook.to_h`'s
// own wire shape (aggregates/attributes/value_objects/entities/
// identified_by/lifecycle) IS what `ir.json`'s top level already
// carries; `translations`/`lineage` (this crate's own two merged-in
// keys) are simply never read here, the same way Ruby's own `project`
// only ever reads `"aggregates"` off `bluebook.to_h` and ignores
// everything else on the wire.
//
// BYTE-EXACT WITH RUBY'S OWN `JSON.generate` OUTPUT IS THE WHOLE POINT
// — a mismatched canonical string means a mismatched SHA256 means Rust
// and Ruby disagree about which era a given shape names. Every object/
// array here is hand-assembled in the SAME field order Ruby's own
// `project`/`project_aggregate`/`project_attribute`/`type_signature`
// build their Hashes in (Ruby Hashes are insertion-ordered, and
// `JSON.generate` preserves that order) — never left to a JSON
// library's own key-ordering default, which for `serde_json` without
// the `preserve_order` feature would alphabetize silently wrong. Only
// LEAF string escaping goes through `serde_json` (`json_string`), which
// is safe: JSON string escaping is one unambiguous spec, not a library
// convention two correct implementations could disagree on.
//
// Verified against a REAL, already-minted edge, not a synthetic one:
// examples/pizzas' own Pizza -> Order translation names its `to:` label
// as "77625c" — this module's own test asserts `mint_label` reproduces
// that exact label from the live `ir.json` Ruby already generated for
// the current (post-rename) shape.

use serde_json::Value;
use sha2::{Digest, Sha256};

pub const LABEL_LENGTH: usize = 6;

// storage_shape.rb's own FORM_VERSION — bump this in the SAME change
// that alters `project`/`canonical`'s output below, on BOTH sides.
pub const FORM_VERSION: i32 = 1;

pub fn mint_hash(ir: &Value) -> String {
    let digest = Sha256::digest(canonical(ir).as_bytes());
    format!("{digest:x}")
}

pub fn mint_label(ir: &Value) -> String {
    let hash = mint_hash(ir);
    hash[..LABEL_LENGTH].to_string()
}

pub fn canonical(ir: &Value) -> String {
    project(ir)
}

fn project(ir: &Value) -> String {
    let name = json_string(ir.get("name").and_then(Value::as_str).unwrap_or(""));
    let mut aggregates: Vec<(String, String)> = ir
        .get("aggregates")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|aggregate| {
                    let name = aggregate.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    (name, project_aggregate(aggregate))
                })
                .collect()
        })
        .unwrap_or_default();
    aggregates.sort_by(|a, b| a.0.cmp(&b.0));
    let aggregates_json = join_array(aggregates.into_iter().map(|(_, j)| j));
    format!("{{\"name\":{name},\"aggregates\":{aggregates_json}}}")
}

fn project_aggregate(aggregate: &Value) -> String {
    let name = json_string(aggregate.get("name").and_then(Value::as_str).unwrap_or(""));

    // `Array(aggregate["identified_by"]).map(&:to_s)` — the wire form is
    // already an array of (possibly dotted) strings when declared, and
    // absent/null when not; `Array(nil) == []`.
    let identity: Vec<String> = match aggregate.get("identified_by") {
        Some(Value::Array(items)) => items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => Vec::new(),
    };
    let identity_json = join_array(identity.into_iter().map(|s| json_string(&s)));

    let lifecycle_field = aggregate
        .get("lifecycle")
        .and_then(|lifecycle| lifecycle.get("field"))
        .and_then(Value::as_str)
        .map(json_string)
        .unwrap_or_else(|| "null".to_string());

    let mut attributes: Vec<(String, String)> = aggregate
        .get("attributes")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|attribute| {
                    let name = attribute.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    (name, project_attribute(aggregate, attribute, &[]))
                })
                .collect()
        })
        .unwrap_or_default();
    attributes.sort_by(|a, b| a.0.cmp(&b.0));
    let attributes_json = join_array(attributes.into_iter().map(|(_, j)| j));

    format!(
        "{{\"name\":{name},\"identity\":{identity_json},\"lifecycle_field\":{lifecycle_field},\"attributes\":{attributes_json}}}"
    )
}

fn project_attribute(aggregate: &Value, attribute: &Value, seen: &[String]) -> String {
    let name = json_string(attribute.get("name").and_then(Value::as_str).unwrap_or(""));
    let list = attribute.get("list").and_then(Value::as_bool).unwrap_or(false);
    let type_name = attribute.get("type").and_then(Value::as_str).unwrap_or("");
    let type_json = type_signature(aggregate, type_name, seen);
    format!("{{\"name\":{name},\"list\":{list},\"type\":{type_json}}}")
}

// A plain type name for a primitive; the type name plus its members'
// full signatures for a value object or entity — so two attributes with
// the same declared type name but different internals are never
// mistaken for unchanged.
fn type_signature(aggregate: &Value, type_name: &str, seen: &[String]) -> String {
    let Some(container) = nested_type(aggregate, type_name) else {
        return json_string(type_name);
    };
    if seen.iter().any(|already| already == type_name) {
        return json_string(type_name);
    }

    let mut next_seen = seen.to_vec();
    next_seen.push(type_name.to_string());

    let mut members: Vec<(String, String)> = container
        .get("attributes")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|member| {
                    let name = member.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    (name, project_attribute(aggregate, member, &next_seen))
                })
                .collect()
        })
        .unwrap_or_default();
    members.sort_by(|a, b| a.0.cmp(&b.0));
    let members_json = join_array(members.into_iter().map(|(_, j)| j));

    let type_name_json = json_string(type_name);
    format!("{{\"type\":{type_name_json},\"members\":{members_json}}}")
}

fn nested_type<'a>(aggregate: &'a Value, type_name: &str) -> Option<&'a Value> {
    let in_list = |key: &str| -> Option<&'a Value> {
        aggregate.get(key).and_then(Value::as_array).and_then(|list| {
            list.iter().find(|entry| entry.get("name").and_then(Value::as_str) == Some(type_name))
        })
    };
    in_list("value_objects").or_else(|| in_list("entities"))
}

fn join_array<I: Iterator<Item = String>>(items: I) -> String {
    format!("[{}]", items.collect::<Vec<_>>().join(","))
}

// JSON string escaping is one unambiguous spec — safe to delegate to
// serde_json for this leaf case, unlike object/array key ORDER, which
// is a library convention this whole file deliberately never delegates.
fn json_string(s: &str) -> String {
    serde_json::to_string(s).expect("a plain &str always serializes")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // The real, live ir.json bin/project_rust already writes for
    // examples/pizzas — not a hand-built fixture, so this test breaks
    // (loudly, correctly) the moment the real shape or this module's
    // own algorithm drifts from Ruby's.
    fn pizzas_ir() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../src/generated/pizzas/ir.json");
        let text = fs::read_to_string(path).expect("rust/src/generated/pizzas/ir.json — run bin/project_rust examples/pizzas first");
        serde_json::from_str(&text).expect("valid JSON")
    }

    #[test]
    fn mint_label_reproduces_the_real_translation_edge_s_own_to_label() {
        // examples/pizzas/bluebook/translations/2-77625c.bluebook declares
        // `from: "e3f3d7", to: "77625c"` for the Pizza -> Order rename —
        // Minter#mint! itself requires `edge.to == label` (this shape's
        // own computed label) before a mint may proceed, so "77625c" is
        // the real, already-verified-by-Ruby answer for the CURRENT
        // (post-rename) shape, not a value this test invents.
        let ir = pizzas_ir();
        assert_eq!(mint_label(&ir), "77625c");
    }

    #[test]
    fn mint_hash_is_stable_across_repeated_calls_on_the_same_shape() {
        let ir = pizzas_ir();
        assert_eq!(mint_hash(&ir), mint_hash(&ir));
    }

    #[test]
    fn a_reordered_but_otherwise_identical_ir_hashes_the_same() {
        // Structural comparison only, never a hash comparison — the
        // whole point storage_shape.rb's own header names: two IR trees
        // that declare the SAME shape in a DIFFERENT key/array order
        // must mint the same label, or a purely cosmetic JSON
        // reformatting would spuriously look like a schema change.
        let ir = pizzas_ir();
        let mut reordered = ir.clone();
        if let Some(aggregates) = reordered.get_mut("aggregates").and_then(Value::as_array_mut) {
            for aggregate in aggregates.iter_mut() {
                if let Some(attributes) = aggregate.get_mut("attributes").and_then(Value::as_array_mut) {
                    attributes.reverse();
                }
            }
        }
        assert_eq!(mint_hash(&ir), mint_hash(&reordered));
    }
}
