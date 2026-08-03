//! The storage-shape projection of a bluebook — the twin of
//! lib/hecksagain/runtime/storage_shape.rb. Exactly the parts of the IR
//! that decide what persisted data looks like: aggregates, attributes
//! (with full value-object/entity structure and cardinality),
//! references, the lifecycle field, the identity paths. Behavior —
//! commands, invariants, queries, transitions, defaults, the routing
//! `version:` — is excluded, and so are the three attribute facts that
//! constrain persisted VALUES rather than shape (`optional`, `pattern`,
//! `admits`) — each decided explicitly; the Ruby twin's header holds
//! the reasoning and names the `admits` gap. Projection runs over the
//! SAME dump form both runtimes hold byte-identical under `bin/parity`
//! (`ir_json::domain_to_value`), so the runtimes cannot disagree on a
//! bump verdict without already failing IR parity. Structural
//! comparison only — never a hash. Era names are minted by the Ruby
//! scaffold alone TODAY, as policy while the canonicalizations are
//! hand-twinned; the policy retires when `bin/parity` mints from both
//! runtimes and diffs every artifact clean — not before, not after.

use serde_json::{json, Value};

pub fn project(domain: &crate::ir::Domain) -> Value {
    let dump = crate::projector::ir_json::domain_to_value(domain);
    let body = dump
        .as_object()
        .and_then(|domains| domains.values().next())
        .cloned()
        .unwrap_or(Value::Null);

    let mut aggregates: Vec<Value> = body
        .get("aggregates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(project_aggregate)
        .collect();
    aggregates.sort_by(|a, b| text(a, "name").cmp(&text(b, "name")));

    json!({
        "name": domain.name,
        "aggregates": aggregates,
    })
}

pub fn same(held: &crate::ir::Domain, current: &crate::ir::Domain) -> bool {
    project(held) == project(current)
}

fn project_aggregate(aggregate: &Value) -> Value {
    let mut attributes: Vec<Value> = aggregate
        .get("attributes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|attribute| project_attribute(aggregate, attribute, &[]))
        .collect();
    attributes.sort_by(|a, b| text(a, "name").cmp(&text(b, "name")));

    json!({
        "name": aggregate.get("name").cloned().unwrap_or(Value::Null),
        // The declared identity paths, AS A LIST, in declaration order —
        // order is semantic (the paths join in order to form the id).
        // No "id" fallback: an aggregate that declares nothing has [],
        // and that is a real declared state, distinct from an aggregate
        // identified by a field named "id".
        "identity": aggregate.get("identified_by").cloned().unwrap_or_else(|| Value::Array(vec![])),
        "lifecycle_field": aggregate.get("lifecycle").and_then(|lifecycle| lifecycle.get("field")).cloned().unwrap_or(Value::Null),
        "attributes": attributes,
    })
}

fn project_attribute(aggregate: &Value, attribute: &Value, seen: &[String]) -> Value {
    let type_name = attribute.get("type").and_then(Value::as_str).unwrap_or_default();
    json!({
        "name": attribute.get("name").cloned().unwrap_or(Value::Null),
        "list": attribute.get("list").and_then(Value::as_bool).unwrap_or(false),
        "type": type_signature(aggregate, type_name, seen),
    })
}

/// A plain type name for a primitive; the type name plus its members'
/// full signatures for a value object or entity — so two attributes
/// with the same declared type name but different internals are never
/// mistaken for unchanged.
fn type_signature(aggregate: &Value, type_name: &str, seen: &[String]) -> Value {
    let Some(container) = nested_type(aggregate, type_name) else {
        return Value::String(type_name.to_string());
    };
    if seen.iter().any(|s| s == type_name) {
        return Value::String(type_name.to_string());
    }

    let mut next_seen = seen.to_vec();
    next_seen.push(type_name.to_string());

    let mut members: Vec<Value> = container
        .get("attributes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|member| project_attribute(aggregate, member, &next_seen))
        .collect();
    members.sort_by(|a, b| text(a, "name").cmp(&text(b, "name")));

    json!({ "type": type_name, "members": members })
}

fn nested_type<'a>(aggregate: &'a Value, type_name: &str) -> Option<&'a Value> {
    let find = |collection: &'a Value| {
        collection.as_array().and_then(|items| {
            items.iter().find(|item| item.get("name").and_then(Value::as_str) == Some(type_name))
        })
    };
    aggregate.get("value_objects").and_then(find).or_else(|| aggregate.get("entities").and_then(find))
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

// Its own fixture-building parses fresh bluebook text via `bluebook::
// parser` — `project` itself (above) takes an already-parsed `Domain`.
#[cfg(all(test, feature = "parser"))]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn fixtures() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../spec/fixtures/eras")
    }

    fn project_file(path: &PathBuf) -> Value {
        let source = fs::read_to_string(path).unwrap();
        project(&crate::bluebook::parser::parse(&source))
    }

    /// The SAME fixture pairs Ruby's spec walks
    /// (spec/fixtures/eras/*.bluebook): every `bump_*` variant must
    /// project differently from base; every `same_*` variant must
    /// project identically. The filename carries the expected verdict,
    /// so the two runtimes read one set of expectations and cannot
    /// drift apart silently.
    #[test]
    fn every_shared_fixture_reaches_the_verdict_its_name_declares() {
        let base = project_file(&fixtures().join("base.bluebook"));

        let mut entries: Vec<PathBuf> = fs::read_dir(fixtures())
            .expect("spec/fixtures/eras must exist — the Ruby spec walks the same directory")
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "bluebook"))
            .collect();
        entries.sort();

        let mut bumps = 0;
        let mut sames = 0;
        for path in entries {
            let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default().to_string();
            if name == "base.bluebook" {
                continue;
            }
            let variant = project_file(&path);
            if name.starts_with("bump_") {
                assert_ne!(base, variant, "{name} must bump the era and did not");
                bumps += 1;
            } else if name.starts_with("same_") {
                assert_eq!(base, variant, "{name} must not bump the era and did");
                sames += 1;
            } else {
                panic!("{name} declares no verdict — fixture names start with bump_ or same_");
            }
        }
        assert!(bumps >= 5, "the bump fixture set shrank — {bumps} left");
        assert!(sames >= 2, "the no-bump fixture set shrank — {sames} left");
    }
}
