//! Layer 1 of the mint audit: a translated record must fit its aggregate's types, patterns,
//! closed sets, admits, invariants and lifecycle. Reads `ir.json` generically, like `ir.rs`.
//!
//! Holds a stored value to what dispatch holds an offered one to (`Value::Validation#validate!`
//! and `Value::Admission` in Ruby; the generated `from_json` and `check_invariants` in Rust), in
//! the same order: a name the value object does not declare, a field left out, closed-set
//! membership, a declared set named by `admits:`, list and scalar shape, `pattern:`, then its own
//! invariants. A refusal is worded as dispatch words it, after the `Aggregate#id:` prefix.

// Depends on `expr_json`, not the `rust` kernel crate: that crate's generated modules are not
// feature-gated, so depending on it would link every domain into every Lambda binary.

use crate::expr_json;
use serde_json::Value;
use std::collections::HashMap;

/// Every structural violation in one translated record; empty means it satisfies its aggregate.
///
/// `domain_ir` is the whole `ir.json`: a declared set named by `admits: "Aggregate::Set"` and a
/// value object another aggregate of the chapter declares are looked up there.
pub fn validate(domain_ir: &Value, aggregate_ir: &Value, id: &str, state: &Value) -> Vec<String> {
    let name = aggregate_ir.get("name").and_then(Value::as_str).unwrap_or("");
    let attributes = aggregate_ir.get("attributes").and_then(Value::as_array).cloned().unwrap_or_default();
    let checker = Checker {
        domain: domain_ir,
        aggregate_name: name,
        id,
        value_objects: index_by_name(aggregate_ir, "value_objects"),
        entities: index_by_name(aggregate_ir, "entities"),
    };

    let mut violations = Vec::new();
    checker.check_attributes(name, Owner::Record, state, &attributes, &mut violations);

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

fn declared_attributes(node: &Value) -> &[Value] {
    node.get("attributes").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default()
}

fn flag(node: &Value, key: &str) -> bool {
    node.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn attribute_name(attr: &Value) -> &str {
    attr.get("name").and_then(Value::as_str).unwrap_or("")
}

/// What an attribute's owner is: a record (the aggregate or one of its entities), whose absent
/// slots are skipped, or a value object, which dispatch builds from input and so holds to its
/// declared names and required fields.
#[derive(Clone, Copy, PartialEq)]
enum Owner {
    Record,
    ValueObject,
}

struct Checker<'a> {
    domain: &'a Value,
    aggregate_name: &'a str,
    id: &'a str,
    value_objects: HashMap<&'a str, &'a Value>,
    entities: HashMap<&'a str, &'a Value>,
}

impl<'a> Checker<'a> {
    fn refuse(&self, violations: &mut Vec<String>, message: String) {
        violations.push(format!("{}#{}: {message}", self.aggregate_name, self.id));
    }

    /// The aggregate's own value object of that name, else the one every aggregate of the chapter
    /// that declares it agrees on (`Value::Coercion#value_object_for`).
    fn value_object(&self, type_name: &str) -> Option<&'a Value> {
        if let Some(vo) = self.value_objects.get(type_name) {
            return Some(vo);
        }
        let declared: Vec<&'a Value> = self
            .domain
            .get("aggregates")
            .and_then(Value::as_array)
            .map(|aggregates| {
                aggregates
                    .iter()
                    .filter_map(|aggregate| index_by_name(aggregate, "value_objects").get(type_name).copied())
                    .collect()
            })
            .unwrap_or_default();
        let first = *declared.first()?;
        declared.iter().all(|other| same_shape(other, first)).then_some(first)
    }

    fn check_attributes(&self, owner_name: &str, owner: Owner, state: &Value, attributes: &[Value], violations: &mut Vec<String>) {
        let Some(state_obj) = state.as_object() else { return };
        for attr in attributes {
            let attr_name = attribute_name(attr);
            let type_name = attr.get("type").and_then(Value::as_str).unwrap_or("");
            let list = flag(attr, "list");
            let optional = flag(attr, "optional");
            let Some(raw) = state_obj.get(attr_name) else { continue };

            if raw.is_null() {
                // A value object's required fields were judged as a whole; a list is never
                // refused for being null (`check_required_fields` skips lists).
                if owner == Owner::Record && !optional && !list {
                    self.refuse_null(owner_name, attr_name, type_name, violations);
                }
                continue;
            }

            if list {
                match raw.as_array() {
                    Some(items) => {
                        for item in items {
                            self.check_value(owner_name, attr_name, type_name, item, attr, violations);
                        }
                    }
                    None => self.refuse(violations, format!("{owner_name}.{attr_name} expects list_of({type_name}), got {}", ruby_inspect(raw))),
                }
            } else {
                self.check_value(owner_name, attr_name, type_name, raw, attr, violations);
                self.check_admits(attr, raw, violations);
            }
        }
    }

    /// A required slot holding null. A value object reads as built from no fields at all, as
    /// `Value::Coercion#nil_argument` builds it: refused for the first required field it lacks,
    /// or accepted when it has none.
    fn refuse_null(&self, owner_name: &str, attr_name: &str, type_name: &str, violations: &mut Vec<String>) {
        match self.value_object(type_name) {
            Some(vo) => self.check_value_object(attr_name, type_name, vo, &Value::Object(serde_json::Map::new()), violations),
            None => self.refuse(violations, format!("{owner_name}.{attr_name} expects {type_name}, got nil")),
        }
    }

    /// `admits: "Aggregate::Set"`: the value must be one of the named closed set's first-column
    /// members, compared as text (`Value::Admission#admit_declared_set`).
    fn check_admits(&self, attr: &Value, raw: &Value, violations: &mut Vec<String>) {
        let Some(admits) = attr.get("admits").and_then(Value::as_str) else { return };
        let name = attribute_name(attr);
        let Some(admitted) = self.admitted_members(admits) else {
            self.refuse(
                violations,
                format!(
                    "{name} admits {admits}, which this chapter does not declare — a closed set is named \
                     Aggregate::SetName, and it must be one the bluebook actually holds"
                ),
            );
            return;
        };

        let offered = match raw.as_object() {
            Some(fields) if fields.len() == 1 => fields.values().next().unwrap_or(raw),
            _ => raw,
        };
        if admitted.contains(&ruby_to_s(offered)) {
            return;
        }
        let listed = admitted.iter().map(|member| inspect_text(member)).collect::<Vec<_>>().join(", ");
        self.refuse(violations, format!("{name} admits {admits} — {listed} — got {}", ruby_inspect(offered)));
    }

    /// The first column of each member row of the set `"Aggregate::Set"` names, as text.
    fn admitted_members(&self, admits: &str) -> Option<Vec<String>> {
        let (aggregate_name, set_name) = admits.split_once("::")?;
        let aggregate = self
            .domain
            .get("aggregates")
            .and_then(Value::as_array)?
            .iter()
            .find(|aggregate| aggregate.get("name").and_then(Value::as_str) == Some(aggregate_name))?;
        let set = *index_by_name(aggregate, "value_objects").get(set_name)?;
        let discriminant = attribute_name(declared_attributes(set).first()?);
        Some(member_rows(set).iter().map(|row| ruby_to_s(row.get(discriminant).unwrap_or(&Value::Null))).collect())
    }

    fn check_value(&self, owner_name: &str, attr_name: &str, type_name: &str, value: &Value, attr: &Value, violations: &mut Vec<String>) {
        if let Some(vo) = self.value_object(type_name) {
            self.check_value_object(attr_name, type_name, vo, value, violations);
            return;
        }
        if let Some(entity) = self.entities.get(type_name) {
            self.check_attributes(type_name, Owner::Record, value, declared_attributes(entity), violations);
            return;
        }

        // A scalar leaf. Unrecognized type names are unconstrained: a false positive would block a
        // real mint.
        if let Some(refusal) = scalar_refusal(owner_name, attr_name, type_name, value) {
            self.refuse(violations, refusal);
            return;
        }
        if let (Some(pattern), Some(text)) = (attr.get("pattern").and_then(Value::as_str), value.as_str()) {
            if matches!(regex::Regex::new(pattern), Ok(re) if !re.is_match(text)) {
                self.refuse(violations, format!("{owner_name}.{attr_name} must match {pattern}, got {}", ruby_inspect(value)));
            }
        }
    }

    /// One stored value object, held to what `Value::Validation#validate!` holds an offered one to.
    fn check_value_object(&self, attr_name: &str, type_name: &str, vo: &Value, raw: &Value, violations: &mut Vec<String>) {
        let declared = declared_attributes(vo);

        // A bare scalar stands in for a single-field value object's one field.
        let wrapped;
        let fields = if raw.is_object() {
            raw
        } else if declared.len() == 1 {
            wrapped = Value::Object(std::iter::once((attribute_name(&declared[0]).to_string(), raw.clone())).collect());
            &wrapped
        } else {
            self.refuse(violations, format!("{attr_name} is a {type_name} — pass its fields as an object, not {}", ruby_inspect(raw)));
            return;
        };
        let Some(given) = fields.as_object() else { return };

        let mut unknown: Vec<&str> = given.keys().map(String::as_str).filter(|key| !declared.iter().any(|attr| attribute_name(attr) == *key)).collect();
        if !unknown.is_empty() {
            unknown.sort();
            let takes = declared.iter().map(attribute_name).collect::<Vec<_>>().join(", ");
            self.refuse(violations, format!("{type_name} does not declare {} — it takes {takes}", unknown.join(", ")));
            return;
        }

        let filled = with_defaults(declared, given);
        let before = violations.len();
        // The first required field left out, as `check_required_fields` refuses it.
        let missing = declared.iter().find(|attr| {
            let present = filled.get(attribute_name(attr)).is_some_and(|value| !value.is_null());
            !present && !flag(attr, "optional") && !flag(attr, "list")
        });
        if let Some(attr) = missing {
            let expected = attr.get("type").and_then(Value::as_str).unwrap_or("");
            self.refuse(violations, format!("{type_name}.{} expects {expected}, got nil", attribute_name(attr)));
            return;
        }

        let filled = Value::Object(filled);
        if flag(vo, "closed_set") && !member_rows(vo).is_empty() {
            self.check_member(type_name, vo, &filled, violations);
            if violations.len() > before {
                return;
            }
        }
        self.check_attributes(type_name, Owner::ValueObject, &filled, declared, violations);

        // Invariants run only when the structure check found nothing: a mistyped value would
        // double-report, or bury the real type error under a "could not be checked".
        if violations.len() == before {
            self.check_invariants(attr_name, type_name, &filled, vo, violations);
        }
    }

    /// `Value::Admission#admit_member`: some member row matches on every field it names, compared
    /// as text. The refusal quotes the first column only.
    fn check_member(&self, type_name: &str, vo: &Value, fields: &Value, violations: &mut Vec<String>) {
        let rows = member_rows(vo);
        let matches_row = |row: &serde_json::Map<String, Value>| {
            row.iter().all(|(field, member)| ruby_to_s(fields.get(field).unwrap_or(&Value::Null)) == ruby_to_s(member))
        };
        if rows.iter().any(matches_row) {
            return;
        }
        let Some(first) = declared_attributes(vo).first().map(attribute_name) else { return };
        let admitted = rows.iter().map(|row| ruby_inspect(row.get(first).unwrap_or(&Value::Null))).collect::<Vec<_>>().join(", ");
        let offered = ruby_inspect(fields.get(first).unwrap_or(&Value::Null));
        self.refuse(violations, format!("{type_name} admits {admitted} — got {offered}"));
    }

    /// Checks a value object's `invariants` through `expr_json`. Fails closed: a malformed or
    /// unsupported `ast` is a violation, since an invariant that cannot be evaluated must not
    /// be minted past.
    fn check_invariants(&self, attr_name: &str, type_name: &str, value: &Value, vo: &Value, violations: &mut Vec<String>) {
        let Some(invariants) = vo.get("invariants").and_then(Value::as_array) else { return };
        let known = with_absent_optionals(vo, value);

        for invariant in invariants {
            let description = invariant.get("description").and_then(Value::as_str).unwrap_or("");
            // An older `ir.json` has no `ast`: nothing to check, so not a violation.
            let Some(ast) = invariant.get("ast") else { continue };

            let expr = match expr_json::parse(ast) {
                Ok(expr) => expr,
                Err(error) => {
                    self.refuse(violations, format!("{attr_name} ({type_name})'s own invariant {description:?} has a malformed ast — {error}"));
                    continue;
                }
            };

            match expr_json::interpret(&expr, &known) {
                Ok(result) if result.truthy() => {}
                Ok(_) => self.refuse(violations, format!("{attr_name} ({type_name}) violates its own invariant — {description}")),
                Err(error) => {
                    self.refuse(violations, format!("{attr_name} ({type_name})'s own invariant {description:?} could not be checked — {error}"))
                }
            }
        }
    }
}

/// Whether two declarations of one value object name agree on every attribute's name, type, list
/// and optional flags (`Value::Coercion#agreed_value_object`).
fn same_shape(left: &Value, right: &Value) -> bool {
    let shape = |vo: &Value| -> Vec<(String, String, bool, bool)> {
        declared_attributes(vo)
            .iter()
            .map(|attr| {
                (
                    attribute_name(attr).to_string(),
                    attr.get("type").and_then(Value::as_str).unwrap_or("").to_string(),
                    flag(attr, "list"),
                    flag(attr, "optional"),
                )
            })
            .collect()
    };
    shape(left) == shape(right)
}

/// A closed set's member rows, each as a field-to-value map. The IR writes a row as a list of
/// `[field, value]` pairs.
fn member_rows(vo: &Value) -> Vec<serde_json::Map<String, Value>> {
    vo.get("members")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter()
                .map(|row| {
                    row.as_array()
                        .map(|pairs| {
                            pairs
                                .iter()
                                .filter_map(Value::as_array)
                                .filter_map(|pair| Some((pair.first()?.as_str()?.to_string(), pair.get(1)?.clone())))
                                .collect()
                        })
                        .unwrap_or_default()
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The value as the Ruby runtime would hold it once it has defaulted what was left out: every
/// declared attribute missing from `given` takes its own `default:`, and every required list
/// reads as empty (`Value::Validation#apply_defaults`). An optional slot stays absent.
fn with_defaults(declared: &[Value], given: &serde_json::Map<String, Value>) -> serde_json::Map<String, Value> {
    let mut filled = given.clone();
    for attr in declared {
        let name = attribute_name(attr);
        if filled.contains_key(name) {
            continue;
        }
        match attr.get("default") {
            Some(default) if !default.is_null() => {
                filled.insert(name.to_string(), default.clone());
            }
            _ if flag(attr, "list") && !flag(attr, "optional") => {
                filled.insert(name.to_string(), Value::Array(Vec::new()));
            }
            _ => {}
        }
    }
    filled
}

/// A scalar that does not fit its declared type, worded as dispatch words it; `None` when it fits
/// or the type is not a plain scalar. A leaf is a String, a number or a boolean, never a list or
/// an object standing in for one.
fn scalar_refusal(owner_name: &str, attr_name: &str, type_name: &str, value: &Value) -> Option<String> {
    let mismatch = || format!("{owner_name}.{attr_name} expects {type_name}, got {}", ruby_inspect(value));
    match type_name {
        "String" if !value.is_string() => Some(mismatch()),
        "Integer" if value.is_i64() => None,
        "Integer" if value.is_u64() => Some(format!("{owner_name}.{attr_name} must fit in a 64-bit integer, got {}", ruby_inspect(value))),
        "Integer" => Some(mismatch()),
        "Float" if value.is_number() => None,
        "Float" => Some(mismatch()),
        "Boolean" if !value.is_boolean() => Some(mismatch()),
        _ => None,
    }
}

/// `Object#to_s` of the Ruby value a JSON value decodes to; text compares by this.
fn ruby_to_s(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// `Object#inspect` of the Ruby value a JSON value decodes to.
fn ruby_inspect(value: &Value) -> String {
    match value {
        Value::Null => "nil".to_string(),
        Value::String(text) => inspect_text(text),
        Value::Array(items) => format!("[{}]", items.iter().map(ruby_inspect).collect::<Vec<_>>().join(", ")),
        other => other.to_string(),
    }
}

fn inspect_text(text: &str) -> String {
    Value::String(text.to_string()).to_string()
}

/// The value an invariant reads: `value` with every declared optional slot it lacks set to null,
/// as the Ruby runtime's own validator does (`Value::Validation#with_absent_optionals`). Absence
/// stays absence in the stored state; an invariant reads it as unset, so `x.set?`, `x.unset?`,
/// `x.nil?` and a comparison with nil all answer for a slot a writer never sent. A name the value
/// object does not declare is not filled, so a lookup of it still refuses.
fn with_absent_optionals(vo: &Value, value: &Value) -> Value {
    let Some(fields) = value.as_object() else { return value.clone() };
    let mut known = fields.clone();
    for attribute in declared_attributes(vo) {
        let Some(name) = attribute.get("name").and_then(Value::as_str) else { continue };
        if flag(attribute, "optional") && !known.contains_key(name) {
            known.insert(name.to_string(), Value::Null);
        }
    }
    Value::Object(known)
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

    // The aggregate alone is the whole domain here; `domain_validate` takes the domain apart.
    fn validate(aggregate_ir: &Value, id: &str, state: &Value) -> Vec<String> {
        domain_validate(&json!({"aggregates": [aggregate_ir]}), aggregate_ir, id, state)
    }

    fn domain_validate(domain_ir: &Value, aggregate_ir: &Value, id: &str, state: &Value) -> Vec<String> {
        super::validate(domain_ir, aggregate_ir, id, state)
    }

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
                    {"name": "size", "type": "String", "list": false, "optional": false, "admits": "Order::Size"}
                ], "invariants": [
                    {"description": "a price is never negative", "canonical": "cents >= 0",
                     "ast": {"op": "compare", "cmp": {"less_than": true, "equal": false, "negated": true},
                             "left": {"op": "lookup", "path": ["cents"]}, "right": {"op": "int", "value": 0}}}
                ]},
                {"name": "Size", "closed_set": true, "invariants": [],
                 "attributes": [{"name": "value", "type": "String", "list": false, "optional": false}],
                 "members": [[["value", "small"]], [["value", "large"]]]},
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
    fn a_value_outside_the_declared_set_it_admits_is_caught_in_dispatchs_words() {
        let state = json!({ "pizza": { "cents": 1200, "size": "medium" }, "toppings": [], "status": "available" });
        let violations = validate(&order_ir(), "p1", &state);
        assert_eq!(violations, vec![r#"Order#p1: size admits Order::Size — "small", "large" — got "medium""#.to_string()]);
    }

    #[test]
    fn an_admits_naming_a_set_the_chapter_does_not_declare_refuses_every_value() {
        let mut ir = order_ir();
        ir["value_objects"][0]["attributes"][1]["admits"] = json!("Order::Missing");
        let state = json!({ "pizza": { "cents": 1200, "size": "small" }, "toppings": [], "status": "available" });
        let violations = validate(&ir, "p1", &state);
        assert_eq!(violations.len(), 1);
        assert!(violations[0].contains("size admits Order::Missing, which this chapter does not declare"), "{violations:?}");
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
        assert!(violations[0].contains("Pizza.cents expects Integer, got nil"), "{violations:?}");
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
    fn a_required_slot_left_out_is_refused_by_name_not_filled_in_for_an_invariant_to_read() {
        let mut ir = layout_ir();
        ir["value_objects"][1]["invariants"] =
            json!([{"description": "a kind", "canonical": "", "ast": {"op": "lookup", "path": ["kind"]}}]);
        let state = json!({"key": {"value": "l1"}, "panels": [{"cells": []}]});
        assert_eq!(validate(&ir, "l1", &state), vec!["Layout#l1: Panel.kind expects String, got nil".to_string()]);
    }

    // A closed set, a multi-field closed set and a value object that holds both, three deep and in a
    // list, with a required list, a defaulted field, an optional field and a list of patterned
    // Strings: every constraint an attribute can declare, reached through a stored value.
    fn constrained_ir() -> Value {
        let attr = |name: &str, ty: &str, list: bool, optional: bool| json!({"name": name, "type": ty, "list": list, "optional": optional});
        json!({
            "name": "Shelf",
            "attributes": [attr("band", "Band", false, false), attr("panels", "Panel", true, false)],
            "entities": [],
            "value_objects": [
                {"name": "Band", "closed_set": true, "invariants": [], "attributes": [attr("size", "String", false, false)],
                 "members": [[["size", "small"]], [["size", "large"]]]},
                {"name": "Pairing", "closed_set": true, "invariants": [],
                 "attributes": [attr("code", "String", false, false), attr("label", "String", false, false)],
                 "members": [[["code", "p"], ["label", "Pee"]], [["code", "q"], ["label", "Cue"]]]},
                {"name": "Panel", "closed_set": false, "invariants": [],
                 "attributes": [attr("band", "Band", false, false), attr("count", "Integer", false, false),
                                {"name": "slug", "type": "String", "list": false, "optional": false, "pattern": "^[a-z]+$"},
                                {"name": "labels", "type": "String", "list": true, "optional": false, "pattern": "^[a-z]+$"},
                                {"name": "pairing", "type": "Pairing", "list": false, "optional": true},
                                {"name": "tone", "type": "String", "list": false, "optional": false, "default": "calm"},
                                attr("inner", "Panel", false, true)]}
            ]
        })
    }

    fn panel() -> Value {
        json!({"band": {"size": "small"}, "count": 1, "slug": "ok", "labels": ["a", "b"]})
    }

    fn shelf_violations(panels: Value) -> Vec<String> {
        validate(&constrained_ir(), "s1", &json!({"band": {"size": "large"}, "panels": panels}))
    }

    fn assert_refused_as(violations: Vec<String>, expected: &str) {
        assert_eq!(violations, vec![format!("Shelf#s1: {expected}")]);
    }

    #[test]
    fn a_value_that_meets_every_constraint_is_accepted_at_every_depth() {
        let mut inner = panel();
        inner["pairing"] = json!({"code": "q", "label": "Cue"});
        let mut outer = panel();
        outer["inner"] = json!({"band": {"size": "large"}, "count": 2, "slug": "in", "labels": [], "inner": inner});
        assert_eq!(shelf_violations(json!([outer, panel()])), Vec::<String>::new());
    }

    #[test]
    fn a_closed_set_refuses_a_non_member_alone_in_a_list_member_and_three_deep() {
        let violations = validate(&constrained_ir(), "s1", &json!({"band": {"size": "huge"}, "panels": []}));
        assert_refused_as(violations, r#"Band admits "small", "large" — got "huge""#);

        let mut bad = panel();
        bad["band"] = json!({"size": "huge"});
        assert_refused_as(shelf_violations(json!([panel(), bad.clone()])), r#"Band admits "small", "large" — got "huge""#);

        let mut deep = panel();
        deep["inner"] = json!({"band": {"size": "small"}, "count": 2, "slug": "in", "labels": [], "inner": {"band": {"size": "small"}, "count": 3, "slug": "x", "labels": [], "inner": bad}});
        assert_refused_as(shelf_violations(json!([deep])), r#"Band admits "small", "large" — got "huge""#);
    }

    #[test]
    fn a_bare_scalar_stands_in_for_a_one_field_set_and_is_checked_the_same() {
        let mut bare = panel();
        bare["band"] = json!("large");
        assert_eq!(shelf_violations(json!([bare])), Vec::<String>::new());
        let mut wrong = panel();
        wrong["band"] = json!("huge");
        assert_refused_as(shelf_violations(json!([wrong])), r#"Band admits "small", "large" — got "huge""#);
    }

    #[test]
    fn a_multi_field_member_must_match_on_every_column_and_quotes_the_first() {
        let mut mixed = panel();
        mixed["pairing"] = json!({"code": "p", "label": "Cue"});
        assert_refused_as(shelf_violations(json!([mixed])), r#"Pairing admits "p", "q" — got "p""#);
    }

    #[test]
    fn a_name_the_value_object_does_not_declare_is_refused_before_anything_else() {
        let mut extra = panel();
        extra["bogus"] = json!(1);
        assert_refused_as(shelf_violations(json!([extra])), "Panel does not declare bogus — it takes band, count, slug, labels, pairing, tone, inner");

        let violations = validate(&constrained_ir(), "s1", &json!({"band": {"size": "small", "bogus": 1}, "panels": []}));
        assert_refused_as(violations, "Band does not declare bogus — it takes size");
    }

    #[test]
    fn a_required_field_left_out_is_refused_while_an_optional_one_a_default_and_a_list_are_not() {
        let mut absent = panel();
        absent.as_object_mut().unwrap().remove("count");
        assert_refused_as(shelf_violations(json!([absent])), "Panel.count expects Integer, got nil");

        let mut sparse = panel();
        sparse.as_object_mut().unwrap().remove("labels");
        assert_eq!(shelf_violations(json!([sparse])), Vec::<String>::new());
    }

    #[test]
    fn a_pattern_is_held_by_every_member_of_a_list_and_by_the_whole_value() {
        let mut bad_label = panel();
        bad_label["labels"] = json!(["a", "B"]);
        assert_refused_as(shelf_violations(json!([bad_label])), r#"Panel.labels must match ^[a-z]+$, got "B""#);

        let mut newline = panel();
        newline["slug"] = json!("ok\n");
        assert_refused_as(shelf_violations(json!([newline])), r#"Panel.slug must match ^[a-z]+$, got "ok\n""#);
    }

    #[test]
    fn a_number_past_signed_64_bits_and_a_whole_float_are_not_integers() {
        let mut big = panel();
        big["count"] = json!(9223372036854775808u64);
        assert_refused_as(shelf_violations(json!([big])), "Panel.count must fit in a 64-bit integer, got 9223372036854775808");

        let mut whole = panel();
        whole["count"] = json!(3.0);
        assert_refused_as(shelf_violations(json!([whole])), "Panel.count expects Integer, got 3.0");

        let mut largest = panel();
        largest["count"] = json!(i64::MAX);
        assert_eq!(shelf_violations(json!([largest])), Vec::<String>::new());
    }

    #[test]
    fn a_list_offered_a_lone_value_is_a_shape_error_and_a_null_list_is_not() {
        assert_refused_as(shelf_violations(json!("x")), r#"Shelf.panels expects list_of(Panel), got "x""#);
        let mut unset = panel();
        unset["labels"] = Value::Null;
        assert_eq!(shelf_violations(json!([unset])), Vec::<String>::new());
    }

    #[test]
    fn a_value_object_another_aggregate_of_the_chapter_declares_is_held_to_its_constraints() {
        let shelf = json!({"name": "Shelf", "attributes": [{"name": "band", "type": "Band", "list": false, "optional": false}],
                           "entities": [], "value_objects": []});
        let vocabulary = json!({"name": "Vocabulary", "attributes": [], "entities": [], "value_objects": [
            {"name": "Band", "closed_set": true, "invariants": [], "attributes": [{"name": "size", "type": "String", "list": false, "optional": false}],
             "members": [[["size", "small"]]]}]});
        let domain = json!({"aggregates": [shelf, vocabulary]});
        let refused = domain_validate(&domain, &shelf, "s1", &json!({"band": {"size": "huge"}}));
        assert_refused_as(refused, r#"Band admits "small" — got "huge""#);
        assert_eq!(domain_validate(&domain, &shelf, "s1", &json!({"band": {"size": "small"}})), Vec::<String>::new());
    }
}
