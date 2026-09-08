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
// CUSTOM VALUE-OBJECT INVARIANT PREDICATES (`invariants: [{canonical:
// "cents >= 0", ast: {...}}]`) ARE NOW CHECKED TOO, for the operators
// `expr_json::interpret` actually implements — see that file's own
// header for exactly which ones, and why the rest cleanly refuse rather
// than being silently skipped or ported speculatively. This closes what
// used to be a deliberate, named gap here: evaluating `canonical` text
// live needed an executable form of it this crate could run without
// either (a) a second, independently-written expression interpreter
// duplicating `rust::kernel::expr` a third time (this codebase's own
// recurring lesson, most recently ADR 0022's whole reason for existing),
// or (b) a direct Cargo dependency on the `rust` kernel crate to reuse
// that interpreter directly — confirmed unsafe to do:
// `rust/src/generated/mod.rs`'s own `pub mod banking; pub mod
// compliance; ...` list is NOT feature-gated (only the `active`
// re-export is), so depending on that crate at all would statically
// bake every domain's generated dispatch code into every Lambda's own
// binary regardless of which `.wasm` it actually loads at runtime — the
// exact per-domain isolation this crate's own Cargo.toml header holds
// itself to. `expr_json.rs`'s own `ast:` JSON — the SAME parsed AST
// `rust/project/expr_emitter.rb` already builds to emit Rust source
// literals, serialized by `lib/hecks/bluebook/expression/ast_json.rb`
// instead — is that build-time export; this file's own `check_value` is
// the small interpreter that consumes it as data.

use crate::expr_json;
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

/// A value object's own declared `invariant("description") { predicate }`
/// entries — `vo["invariants"]`, each `{description, canonical, ast}`
/// (`lib/hecks/bluebook/value_object.rb`'s own `invariants:` IR
/// emission; `ast` is `expr_json::parse`'s own input, `Expression::
/// AstJson.emit_predicate`'s output). FAILS CLOSED — a malformed `ast`
/// or an operator `expr_json::interpret` doesn't support yet is pushed
/// as a real violation, refusing the mint, the same as a genuine
/// invariant failure would — not silently skipped. That is the
/// deliberate difference from `check_value`'s own "unrecognized type
/// name" tolerance just below: an unrecognized TYPE genuinely could be
/// anything (no information either way, so guessing would risk a false
/// positive worse than checking nothing), but an invariant this file
/// KNOWS exists and simply cannot yet evaluate is real, actionable
/// information — reporting it loudly is what lets an author either
/// simplify the predicate or wait for `expr_json.rs`'s own coverage to
/// grow, rather than silently minting past it.
fn check_invariants(aggregate_name: &str, id: &str, attr_name: &str, type_name: &str, value: &Value, vo: &Value, violations: &mut Vec<String>) {
    let Some(invariants) = vo.get("invariants").and_then(Value::as_array) else { return };

    for invariant in invariants {
        let description = invariant.get("description").and_then(Value::as_str).unwrap_or("");
        // No `ast` key at all — an `ir.json` built before this
        // capability existed (or by a generator this validator doesn't
        // fully trust yet). Nothing to check against, and no claim this
        // audit ever made before that it's checking it — not a
        // violation, unlike a PRESENT-but-malformed or PRESENT-but-
        // unsupported `ast`, both of which ARE.
        let Some(ast) = invariant.get("ast") else { continue };

        let expr = match expr_json::parse(ast) {
            Ok(expr) => expr,
            Err(error) => {
                violations.push(format!(
                    "{aggregate_name}#{id}: {attr_name} ({type_name})'s own invariant {description:?} has a malformed ast — {error}"
                ));
                continue;
            }
        };

        match expr_json::interpret(&expr, value) {
            Ok(result) if result.truthy() => {}
            Ok(_) => violations.push(format!("{aggregate_name}#{id}: {attr_name} ({type_name}) violates its own invariant — {description}")),
            Err(error) => violations.push(format!(
                "{aggregate_name}#{id}: {attr_name} ({type_name})'s own invariant {description:?} could not be checked — {error}"
            )),
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
        let before = violations.len();
        check_attributes(aggregate_name, id, value, &nested, value_objects, entities, violations);
        // STRUCTURE FIRST, INVARIANT SECOND — and only when the struct
        // check found nothing wrong. A value already flagged for a
        // wrong type/pattern/admits has nothing coherent for its own
        // `invariant` predicate to say about it either (`cents >= 0`
        // means nothing once `cents` itself isn't the Integer it's
        // declared as) — checking anyway would either double-report the
        // SAME underlying problem under two different violation
        // messages, or (worse) `expr_json::interpret` refusing to
        // compare a non-numeric value would surface as its own separate
        // "could not be checked" violation, obscuring the real,
        // first-order type mismatch behind noise.
        if violations.len() == before {
            check_invariants(aggregate_name, id, attr_name, type_name, value, vo, violations);
        }
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
                ], "invariants": [
                    {"description": "a price is never negative", "canonical": "cents >= 0",
                     "ast": {"op": "compare", "cmp": {"less_than": true, "equal": false, "negated": true},
                             "left": {"op": "lookup", "path": ["cents"]}, "right": {"op": "int", "value": 0}}}
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
    fn a_value_object_that_violates_its_own_declared_invariant_is_caught() {
        let state = json!({ "pizza": { "cents": -500, "size": "large" }, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("a price is never negative"), "{violations:?}");
    }

    #[test]
    fn a_value_object_that_holds_its_own_invariant_has_no_violation_for_it() {
        let state = json!({ "pizza": { "cents": 0, "size": "large" }, "toppings": [], "status": "available" });
        assert_eq!(validate(&order_ir(), "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn an_invariant_with_no_ast_key_at_all_is_not_checked_and_not_a_violation() {
        // Backward compatibility with an ir.json built before `ast:`
        // existed — nothing to evaluate, so nothing claimed.
        let mut ir = order_ir();
        ir["value_objects"][0]["invariants"][0].as_object_mut().unwrap().remove("ast");
        let state = json!({ "pizza": { "cents": -500, "size": "large" }, "toppings": [], "status": "available" });
        assert_eq!(validate(&ir, "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn an_operator_expr_json_does_not_yet_interpret_refuses_the_mint_rather_than_skipping_it() {
        let mut ir = order_ir();
        ir["value_objects"][0]["invariants"][0]["ast"] = json!({
            "op": "presence", "receiver": {"op": "lookup", "path": ["cents"]}, "negated": false
        });
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [], "status": "available" });
        let violations = validate(&ir, "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("could not be checked"), "{violations:?}");
    }

    #[test]
    fn a_null_non_optional_field_is_caught() {
        let state = json!({ "pizza": null, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("pizza"), "{violations:?}");
    }
}
