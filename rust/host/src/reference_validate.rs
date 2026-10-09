//! Layer 1 of the mint audit: a translated record must fit its aggregate's types, patterns,
//! admits, invariants and lifecycle. Reads `ir.json` generically, like `ir.rs`.

// Depends on `expr_json`, not the `rust` kernel crate: that crate's generated modules are not
// feature-gated, so depending on it would link every domain into every Lambda binary.

use crate::expr_json;
use serde_json::Value;
use std::collections::HashMap;

/// Every structural violation in one translated record; empty means it satisfies its aggregate.
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

/// The value an invariant reads: `value` with every declared optional slot it lacks set to null,
/// as the Ruby runtime's own validator does (`Value::Validation#with_absent_optionals`). Absence
/// stays absence in the stored state; an invariant reads it as unset, so `x.set?`, `x.unset?`,
/// `x.nil?` and a comparison with nil all answer for a slot a writer never sent. A name the value
/// object does not declare is not filled, so a lookup of it still refuses.
fn with_absent_optionals(vo: &Value, value: &Value) -> Value {
    let Some(fields) = value.as_object() else { return value.clone() };
    let mut known = fields.clone();
    let declared = vo.get("attributes").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    for attribute in declared {
        let optional = attribute.get("optional").and_then(Value::as_bool).unwrap_or(false);
        let Some(name) = attribute.get("name").and_then(Value::as_str) else { continue };
        if optional && !known.contains_key(name) {
            known.insert(name.to_string(), Value::Null);
        }
    }
    Value::Object(known)
}

/// Checks a value object's `invariants` through `expr_json`. Fails closed: a malformed or
/// unsupported `ast` is a violation, since an invariant that cannot be evaluated must not
/// be minted past.
fn check_invariants(aggregate_name: &str, id: &str, attr_name: &str, type_name: &str, value: &Value, vo: &Value, violations: &mut Vec<String>) {
    let Some(invariants) = vo.get("invariants").and_then(Value::as_array) else { return };
    let known = with_absent_optionals(vo, value);

    for invariant in invariants {
        let description = invariant.get("description").and_then(Value::as_str).unwrap_or("");
        // An older `ir.json` has no `ast`: nothing to check, so not a violation.
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

        match expr_json::interpret(&expr, &known) {
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
        // Invariants run only when the structure check found nothing: a mistyped value would
        // double-report, or bury the real type error under a "could not be checked".
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

    // A scalar leaf. Unrecognized type names are unconstrained: a false positive would block a
    // real mint.
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
        // An `ir.json` built before `ast:` existed: nothing to evaluate, so nothing claimed.
        let mut ir = order_ir();
        ir["value_objects"][0]["invariants"][0].as_object_mut().unwrap().remove("ast");
        let state = json!({ "pizza": { "cents": -500, "size": "large" }, "toppings": [], "status": "available" });
        assert_eq!(validate(&ir, "p1", &state), Vec::<String>::new());
    }

    #[test]
    fn an_invariant_using_a_newer_operator_is_checked_not_refused() {
        // `!cents.blank?` (presence): every node Ruby interprets is interpreted here too.
        let mut ir = order_ir();
        ir["value_objects"][0]["attributes"][0]["optional"] = json!(true);
        ir["value_objects"][0]["invariants"][0]["ast"] = json!({
            "op": "presence", "receiver": {"op": "lookup", "path": ["cents"]}, "negated": false
        });
        let good = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [], "status": "available" });
        assert_eq!(validate(&ir, "p1", &good), Vec::<String>::new());
        let bad = json!({ "pizza": { "cents": null, "size": "large" }, "toppings": [], "status": "available" });
        let violations = validate(&ir, "p1", &bad);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("violates its own invariant"), "{violations:?}");
    }

    #[test]
    fn an_invariant_whose_evaluation_errors_refuses_the_mint_with_rubys_wording() {
        let mut ir = order_ir();
        ir["value_objects"][0]["invariants"][0]["ast"] = json!({
            "op": "empty", "receiver": {"op": "lookup", "path": ["cents"]}
        });
        let state = json!({ "pizza": { "cents": 1200, "size": "large" }, "toppings": [], "status": "available" });
        let violations = validate(&ir, "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("could not be checked — empty? expects a list or string, got 1200"), "{violations:?}");
    }

    #[test]
    fn a_null_non_optional_field_is_caught() {
        let state = json!({ "pizza": null, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("pizza"), "{violations:?}");
    }

    // A page of panels, each optionally holding a note, which optionally holds a link; a panel
    // also lists cells that may hold a note. Every rule reads a slot a stored value may leave out.
    fn layout_ir() -> Value {
        let attr = |name: &str, ty: &str, list: bool, optional: bool| {
            json!({"name": name, "type": ty, "list": list, "optional": optional})
        };
        let lookup = |path: &[&str]| json!({"op": "lookup", "path": path});
        let unset = |path: &[&str]| json!({"op": "assignment", "receiver": lookup(path), "negated": true});
        let set = |path: &[&str]| json!({"op": "assignment", "receiver": lookup(path), "negated": false});
        let not_empty = |path: &[&str]| json!({"op": "not", "expr": {"op": "empty", "receiver": {"op": "to_s", "receiver": lookup(path)}}});
        let either = |left: Value, right: Value| json!({"op": "or", "left": left, "right": right});
        let differs = |path: &[&str], text: &str| json!({"op": "compare", "cmp": {"less_than": false, "equal": true, "negated": true},
            "left": lookup(path), "right": {"op": "str", "value": text}});
        let rule = |description: &str, ast: Value| json!({"description": description, "canonical": "", "ast": ast});
        json!({
            "name": "Layout",
            "attributes": [attr("key", "LayoutKey", false, false), attr("panels", "Panel", true, false)],
            "entities": [],
            "value_objects": [
                {"name": "LayoutKey", "attributes": [attr("value", "String", false, false)], "invariants": []},
                {"name": "Panel",
                 "attributes": [attr("kind", "String", false, false), attr("title", "String", false, true),
                                attr("note", "Note", false, true), attr("cells", "Cell", true, false)],
                 "invariants": [
                    rule("a title is not blank when given", either(unset(&["title"]), not_empty(&["title"]))),
                    rule("a callout carries a note", either(differs(&["kind"], "callout"), set(&["note"]))),
                    rule("a quiet panel has no loud note", either(differs(&["kind"], "quiet"), differs(&["note", "tone"], "loud")))]},
                {"name": "Cell",
                 "attributes": [attr("label", "String", false, false), attr("note", "Note", false, true)],
                 "invariants": [rule("a cell's note has words", either(unset(&["note"]), not_empty(&["note", "text"])))]},
                {"name": "Note",
                 "attributes": [attr("text", "String", false, false), attr("tone", "String", false, true),
                                attr("link", "Link", false, true)],
                 "invariants": [rule("a tone is calm or loud", either(unset(&["tone"]), json!({"op": "compare",
                    "cmp": {"less_than": false, "equal": true, "negated": false}, "left": lookup(&["tone"]),
                    "right": {"op": "str", "value": "calm"}})))]},
                {"name": "Link",
                 "attributes": [attr("href", "String", false, false), attr("label", "String", false, true)],
                 "invariants": [rule("a link label is not blank when given", either(unset(&["label"]), not_empty(&["label"])))]}
            ]
        })
    }

    fn layout_violations(panels: Value) -> Vec<String> {
        validate(&layout_ir(), "l1", &json!({"key": {"value": "l1"}, "panels": panels}))
    }

    #[test]
    fn a_stored_panel_with_every_optional_slot_absent_is_accepted() {
        assert_eq!(layout_violations(json!([{"kind": "plain", "cells": [{"label": "c"}]}])), Vec::<String>::new());
    }

    #[test]
    fn an_absent_slot_reads_the_same_as_an_explicit_null() {
        let absent = layout_violations(json!([{"kind": "callout", "cells": []}]));
        let null = layout_violations(json!([{"kind": "callout", "note": null, "title": null, "cells": []}]));
        assert_eq!(absent.len(), 1, "{absent:?}");
        assert_eq!(absent, null);
    }

    #[test]
    fn a_rule_that_needs_an_absent_slot_refuses_with_its_description_not_a_lookup_error() {
        let violations = layout_violations(json!([{"kind": "callout", "cells": []}]));
        assert_eq!(violations.len(), 1, "{violations:?}");
        assert!(violations[0].contains("violates its own invariant — a callout carries a note"), "{violations:?}");
    }

    #[test]
    fn a_path_through_an_absent_value_object_reads_as_nil() {
        assert_eq!(layout_violations(json!([{"kind": "quiet", "cells": []}])), Vec::<String>::new());
    }

    #[test]
    fn an_absent_slot_three_levels_down_is_accepted_and_a_present_one_is_still_checked() {
        let absent = json!([{"kind": "plain", "cells": [{"label": "c", "note": {"text": "n", "link": {"href": "/a"}}}]}]);
        let blank = json!([{"kind": "plain", "cells": [{"label": "c", "note": {"text": "n", "link": {"href": "/a", "label": ""}}}]}]);
        assert_eq!(layout_violations(absent), Vec::<String>::new());
        let violations = layout_violations(blank);
        assert!(violations.len() == 1 && violations[0].contains("a link label is not blank when given"), "{violations:?}");
    }

    #[test]
    fn absent_slots_inside_list_members_are_accepted_and_a_bad_member_is_named() {
        let members = json!([{"kind": "plain", "cells": [{"label": "a"}, {"label": "b", "note": {"text": "n"}}]}]);
        let bad = json!([{"kind": "plain", "cells": [{"label": "a"}, {"label": "b", "note": {"text": ""}}]}]);
        assert_eq!(layout_violations(members), Vec::<String>::new());
        let violations = layout_violations(bad);
        assert!(violations.iter().any(|v| v.contains("a cell's note has words")), "{violations:?}");
    }

    #[test]
    fn a_name_the_value_object_does_not_declare_still_refuses_to_resolve() {
        let mut ir = layout_ir();
        ir["value_objects"][1]["invariants"] =
            json!([{"description": "a typo", "canonical": "", "ast": {"op": "lookup", "path": ["tittle"]}}]);
        let state = json!({"key": {"value": "l1"}, "panels": [{"kind": "plain", "cells": []}]});
        let violations = validate(&ir, "l1", &state);
        assert_eq!(violations.len(), 1, "{violations:?}");
        assert!(violations[0].contains("could not be checked — cannot resolve \"tittle\" — no such attribute or argument"), "{violations:?}");
    }

    #[test]
    fn a_required_slot_left_out_is_not_filled_in() {
        let mut ir = layout_ir();
        ir["value_objects"][1]["invariants"] =
            json!([{"description": "a kind", "canonical": "", "ast": {"op": "lookup", "path": ["kind"]}}]);
        let state = json!({"key": {"value": "l1"}, "panels": [{"cells": []}]});
        let violations = validate(&ir, "l1", &state);
        assert!(violations.iter().any(|v| v.contains("cannot resolve \"kind\"")), "{violations:?}");
    }
}
