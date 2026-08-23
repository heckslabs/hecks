// LAYER 1 of the mint-time audit — structural parity with Ruby's own
// `Runtime::Instance.new`/`Value.hydrate` (rescued for
// `InvariantViolation`/`TypeMismatch` by `Translation::Audit::
// LayerOne`) plus that same module's own lifecycle-field check: every
// translated record must satisfy its aggregate's declared shape (types,
// patterns, admits/closed-set) and lifecycle (its state field, if any,
// must be a value the lifecycle actually reaches). This is what turns a
// silent shape corruption from a compiled-SQL bug into a refused mint.
//
// Generic and IR-driven, matching `rust/host`'s own established
// discipline (`ir.rs` already reads everything generically via
// `serde_json::Value`, no per-domain generated type) — reads straight
// off `ir.json`'s `aggregates[].{attributes,value_objects,entities,
// lifecycle}`, the SAME metadata `rust/codegen` already compiles types
// from, just consumed as data here instead of compiled to Rust source.
//
// A DELIBERATE, NAMED GAP from Ruby's own full guarantee, not a silent
// omission: custom VALUE-OBJECT INVARIANT PREDICATES (`invariants:
// [{canonical: "cents >= 0"}]`, arbitrary expression text) are NOT
// evaluated here. Everything else Layer 1 checks in Ruby — type shape,
// pattern, admits/closed-set, lifecycle membership — IS. Evaluating
// `canonical` text live needs an executable form of it this crate can
// run without either (a) a second, independently-written expression
// interpreter duplicating `rust::kernel::expr` a third time (this
// codebase's own recurring lesson, most recently ADR 0022's whole
// reason for existing), or (b) a direct Cargo dependency on the `rust`
// kernel crate to reuse that interpreter directly — confirmed unsafe to
// do: `rust/src/generated/mod.rs`'s own `pub mod banking; pub mod
// compliance; ...` list is NOT feature-gated (only the `active`
// re-export is), so depending on that crate at all would statically
// bake every domain's generated dispatch code into every Lambda's own
// binary regardless of which `.wasm` it actually loads at runtime — the
// exact per-domain isolation this crate's own Cargo.toml header holds
// itself to. Closing this gap for real needs a NEW build-time export
// (the SAME parsed AST `rust/project/expr_emitter.rb` already builds to
// emit Rust source literals, serialized to `ir.json` as JSON data
// instead) plus a small interpreter here that consumes it as data — a
// real, buildable next step, deliberately scoped out of this pass
// rather than rushed into place without it.

use serde_json::Value;
use std::collections::HashMap;

/// Every structural violation found in one translated record — empty
/// means it satisfies its aggregate's own declared shape and lifecycle.
/// `aggregate_ir` is the aggregate's own node from `ir.json`'s
/// `aggregates` array (attributes/value_objects/entities/lifecycle).
pub fn validate(aggregate_ir: &Value, id: &str, state: &Value) -> Vec<String> {
    let name = aggregate_ir.get("name").and_then(Value::as_str).unwrap_or("");
    let value_objects = index_by_name(aggregate_ir, "value_objects");
    let entities = index_by_name(aggregate_ir, "entities");
    let attributes = aggregate_ir.get("attributes").and_then(Value::as_array).cloned().unwrap_or_default();

    let mut violations = Vec::new();
    check_attributes(name, id, state, &attributes, &value_objects, &entities, &mut violations);

    if let Some(lifecycle) = aggregate_ir.get("lifecycle") {
        check_lifecycle(name, id, state, lifecycle, &mut violations);
    }
    violations
}

fn index_by_name<'a>(node: &'a Value, key: &str) -> HashMap<&'a str, &'a Value> {
    node.get(key)
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(|item| item.get("name").and_then(Value::as_str).map(|n| (n, item))).collect())
        .unwrap_or_default()
}

fn check_attributes(
    aggregate_name: &str,
    id: &str,
    state: &Value,
    attributes: &[Value],
    value_objects: &HashMap<&str, &Value>,
    entities: &HashMap<&str, &Value>,
    violations: &mut Vec<String>,
) {
    let Some(state_obj) = state.as_object() else { return };
    for attr in attributes {
        let attr_name = attr.get("name").and_then(Value::as_str).unwrap_or("");
        let type_name = attr.get("type").and_then(Value::as_str).unwrap_or("");
        let list = attr.get("list").and_then(Value::as_bool).unwrap_or(false);
        let optional = attr.get("optional").and_then(Value::as_bool).unwrap_or(false);
        let Some(raw) = state_obj.get(attr_name) else { continue };

        if raw.is_null() {
            if !optional {
                violations.push(format!("{aggregate_name}#{id}: {attr_name} is null, not declared optional"));
            }
            continue;
        }

        if list {
            match raw.as_array() {
                Some(items) => {
                    for item in items {
                        check_value(aggregate_name, id, attr_name, type_name, item, attr, value_objects, entities, violations);
                    }
                }
                None => violations.push(format!("{aggregate_name}#{id}: {attr_name} is declared a list, but the translated value isn't one")),
            }
        } else {
            check_value(aggregate_name, id, attr_name, type_name, raw, attr, value_objects, entities, violations);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn check_value(
    aggregate_name: &str,
    id: &str,
    attr_name: &str,
    type_name: &str,
    value: &Value,
    attr: &Value,
    value_objects: &HashMap<&str, &Value>,
    entities: &HashMap<&str, &Value>,
    violations: &mut Vec<String>,
) {
    if let Some(vo) = value_objects.get(type_name) {
        let nested = vo.get("attributes").and_then(Value::as_array).cloned().unwrap_or_default();
        check_attributes(aggregate_name, id, value, &nested, value_objects, entities, violations);
        return;
    }
    if let Some(entity) = entities.get(type_name) {
        let nested = entity.get("attributes").and_then(Value::as_array).cloned().unwrap_or_default();
        check_attributes(aggregate_name, id, value, &nested, value_objects, entities, violations);
        return;
    }

    // A scalar leaf — String/Integer/Float/Boolean, or a type name this
    // validator doesn't recognize at all (a domain scalar alias, a
    // reference/identity type). Unrecognized names are treated as
    // unconstrained rather than guessed at: a false positive here would
    // block a real mint, the one failure mode worse than checking
    // nothing.
    if !scalar_type_matches(type_name, value) {
        violations.push(format!("{aggregate_name}#{id}: {attr_name} is {value}, not a {type_name}"));
        return;
    }
    if let Some(pattern) = attr.get("pattern").and_then(Value::as_str) {
        if let Some(text) = value.as_str() {
            match regex::Regex::new(pattern) {
                Ok(re) if !re.is_match(text) => {
                    violations.push(format!("{aggregate_name}#{id}: {attr_name} ({value}) doesn't match its own declared pattern"));
                }
                _ => {}
            }
        }
    }
    if let Some(admits) = attr.get("admits").and_then(Value::as_array) {
        if !admits.is_empty() && !admits.iter().any(|allowed| allowed == value) {
            violations.push(format!("{aggregate_name}#{id}: {attr_name} is {value}, not one of its declared admits"));
        }
    }
}

fn scalar_type_matches(type_name: &str, value: &Value) -> bool {
    match type_name {
        "String" => value.is_string(),
        "Integer" => value.is_i64() || value.is_u64(),
        "Float" => value.is_f64() || value.is_i64() || value.is_u64(),
        "Boolean" => value.is_boolean(),
        _ => true,
    }
}

fn check_lifecycle(aggregate_name: &str, id: &str, state: &Value, lifecycle: &Value, violations: &mut Vec<String>) {
    let field = lifecycle.get("field").and_then(Value::as_str).unwrap_or("");
    if field.is_empty() {
        return;
    }
    let Some(held) = state.get(field) else { return };
    if held.is_null() {
        return;
    }

    let mut allowed: Vec<&str> = lifecycle
        .get("transitions")
        .and_then(Value::as_array)
        .map(|ts| ts.iter().filter_map(|t| t.get("to_state").and_then(Value::as_str)).collect())
        .unwrap_or_default();
    if let Some(default) = lifecycle.get("default").and_then(Value::as_str) {
        allowed.push(default);
    }

    let ok = held.as_str().map(|h| allowed.contains(&h)).unwrap_or(false);
    if !ok {
        violations.push(format!("{aggregate_name}#{id}: {field} is {held}, a state this era's lifecycle never reaches"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn order_ir() -> Value {
        json!({
            "name": "Order",
            "attributes": [
                {"name": "pizza", "type": "Pizza", "list": false, "optional": false},
                {"name": "toppings", "type": "Topping", "list": true, "optional": false},
                {"name": "status", "type": "String", "list": false, "optional": true}
            ],
            "value_objects": [
                {"name": "Pizza", "attributes": [
                    {"name": "cents", "type": "Integer", "list": false, "optional": false},
                    {"name": "size", "type": "String", "list": false, "optional": false, "admits": ["small", "large"]}
                ]},
                {"name": "Topping", "attributes": [
                    {"name": "name", "type": "String", "list": false, "optional": false, "pattern": "[^ \\t\\n\\r]"}
                ]}
            ],
            "entities": [],
            "lifecycle": { "field": "status", "default": "available", "transitions": [{"command": "Purchase", "to_state": "sold", "from_state": "available"}] }
        })
    }

    #[test]
    fn a_shape_matching_record_has_no_violations() {
        let state = json!({
            "pizza": { "cents": 1200, "size": "large" },
            "toppings": [{ "name": "Basil" }, { "name": "Olives" }],
            "status": "available"
        });
        assert_eq!(validate(&order_ir(), "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn a_wrong_scalar_type_nested_two_levels_deep_is_caught() {
        let state = json!({
            "pizza": { "cents": "not a number", "size": "large" },
            "toppings": [],
            "status": "available"
        });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("cents"), "{violations:?}");
    }

    #[test]
    fn a_value_outside_its_own_admits_set_is_caught() {
        let state = json!({ "pizza": { "cents": 1200, "size": "medium" }, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("size"), "{violations:?}");
    }

    #[test]
    fn a_pattern_violation_inside_a_list_of_entities_is_caught() {
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [{ "name": "   " }], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("name"), "{violations:?}");
    }

    #[test]
    fn a_lifecycle_state_the_lifecycle_never_reaches_is_caught() {
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [], "status": "vaporized" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("status"), "{violations:?}");
    }

    #[test]
    fn a_declared_reachable_lifecycle_state_passes() {
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [], "status": "sold" });
        assert_eq!(validate(&order_ir(), "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn an_absent_optional_field_is_not_a_violation() {
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [] });
        assert_eq!(validate(&order_ir(), "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn a_null_non_optional_field_is_caught() {
        let state = json!({ "pizza": null, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("pizza"), "{violations:?}");
    }
}
