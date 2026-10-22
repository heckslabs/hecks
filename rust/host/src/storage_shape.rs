//! Port of storage_shape.rb's `project`/`mint_hash`/`mint_label`: the canonical shape hash.
//! Byte-exact with Ruby's `JSON.generate`, or the two disagree about which era a shape names.

use serde_json::Value;
use sha2::{Digest, Sha256};

pub const LABEL_LENGTH: usize = 6;

// Mirrors FORM_VERSION in storage_shape.rb; bump both when `canonical`'s output changes.
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
                    let name = aggregate
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
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

    // Ruby's `Array(aggregate["identified_by"]).map(&:to_s)`: absent or null is `[]`.
    let identity: Vec<String> = match aggregate.get("identified_by") {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| item.as_str().map(str::to_string))
            .collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => Vec::new(),
    };
    let identity_json = join_array(identity.into_iter().map(|s| json_string(&s)));

    let lifecycle_field = aggregate
        .get("lifecycle")
        .and_then(|lifecycle| lifecycle.get("field"))
        .and_then(Value::as_str)
        .map_or_else(|| "null".to_string(), json_string);

    let mut attributes: Vec<(String, String)> = aggregate
        .get("attributes")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|attribute| {
                    let name = attribute
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
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
    let list = attribute
        .get("list")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let type_name = attribute.get("type").and_then(Value::as_str).unwrap_or("");
    let type_json = type_signature(aggregate, type_name, seen);
    format!("{{\"name\":{name},\"list\":{list},\"type\":{type_json}}}")
}

// A primitive is its type name; a value object or entity adds its members' signatures, so
// same-named types with different internals never look unchanged.
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
                    let name = member
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
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
        aggregate
            .get(key)
            .and_then(Value::as_array)
            .and_then(|list| {
                list.iter()
                    .find(|entry| entry.get("name").and_then(Value::as_str) == Some(type_name))
            })
    };
    in_list("value_objects").or_else(|| in_list("entities"))
}

fn join_array<I: Iterator<Item = String>>(items: I) -> String {
    format!("[{}]", items.collect::<Vec<_>>().join(","))
}

// Leaf escaping is one unambiguous spec, so serde_json is safe here; key order is not.
fn json_string(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const REPO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");

    // spec/fixtures/storage_shape_vectors.json is asserted by spec/runtime/storage_shape_spec.rb
    // too, so a drift in either implementation fails a test on its own side.
    fn vectors() -> Vec<Value> {
        serde_json::from_str(include_str!(
            "../../../spec/fixtures/storage_shape_vectors.json"
        ))
        .expect("valid vectors JSON")
    }

    // A vector carries its IR inline, or names an ir.json in the repo (the real pizzas one).
    fn ir_of(vector: &Value) -> Value {
        if let Some(ir) = vector.get("ir") {
            return ir.clone();
        }
        let file = vector["ir_file"].as_str().expect("ir or ir_file");
        let text = fs::read_to_string(format!("{REPO}/{file}"))
            .unwrap_or_else(|e| panic!("{file}: {e} - run hecks project_rust examples/pizzas"));
        serde_json::from_str(&text).expect("valid JSON")
    }

    #[test]
    fn every_golden_vector_matches_the_ruby_canonical_hash_and_label() {
        let vectors = vectors();
        assert!(vectors.len() >= 8, "the vector file went missing");
        for vector in &vectors {
            let name = vector["name"].as_str().unwrap();
            let ir = ir_of(vector);
            assert_eq!(
                canonical(&ir),
                vector["canonical"].as_str().unwrap(),
                "{name}"
            );
            assert_eq!(mint_hash(&ir), vector["hash"].as_str().unwrap(), "{name}");
            assert_eq!(mint_label(&ir), vector["label"].as_str().unwrap(), "{name}");
        }
    }

    #[test]
    fn the_real_translation_edge_label_is_among_the_vectors() {
        // examples/pizzas/bluebook/translations/2-77625c.bluebook names "77625c" as the label Ruby
        // computed for this shape (Minter#mint! requires `edge.to == label`).
        let labels: Vec<String> = vectors()
            .iter()
            .map(|v| v["label"].as_str().unwrap().to_string())
            .collect();
        assert!(labels.iter().any(|label| label == "77625c"));
    }

    #[test]
    fn a_reordered_but_otherwise_identical_ir_hashes_the_same() {
        // Pins that attribute order is normalised: reordering must not look like a schema change.
        let ir = ir_of(
            vectors()
                .iter()
                .find(|v| v["name"] == "pizzas_translation_edge_77625c")
                .unwrap(),
        );
        let mut reordered = ir.clone();
        if let Some(aggregates) = reordered
            .get_mut("aggregates")
            .and_then(Value::as_array_mut)
        {
            for aggregate in aggregates.iter_mut() {
                if let Some(attributes) = aggregate
                    .get_mut("attributes")
                    .and_then(Value::as_array_mut)
                {
                    attributes.reverse();
                }
            }
        }
        assert_eq!(mint_hash(&ir), mint_hash(&reordered));
    }
}
