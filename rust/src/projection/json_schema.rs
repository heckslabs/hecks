//! JSON Schema projection — draft 2020-12 schema per command, from the IR.
//!
//! The published-language projection of a command's payload contract
//! (PLAN-json-schema-projection, 2026-07-19). ONE canonical shape that
//! the served form renders from (enum→dropdown, type→input,
//! required→asterisk), that external clients validate against, and that
//! the MCP door can declare as a per-command inputSchema. It is the
//! PORTABLE projection of the payload law — the payload gate
//! (runtime/payload_gate.rs) remains the enforcement ; schema is what the
//! outer rings read. Both come from the same IR, so neither drifts.
//!
//! Mapping : command attributes → properties ; `required: true` → required ;
//! one_of (scalar enum_values, or a VO's member discriminants) → enum ;
//! wrapper VO → its inner primitive type ; reference_to X → an id string ;
//! the stray-key door rule → additionalProperties:false.
//!
//! Usage :
//!   let schema = json_schema::command_schema(agg, cmd);

use crate::ir::{Aggregate, Attribute, Command};
use serde_json::{json, Map, Value};

/// Draft-2020-12 JSON Schema for one command's payload.
pub fn command_schema(agg: &Aggregate, cmd: &Command) -> Value {
    let mut props = Map::new();
    let mut required: Vec<Value> = Vec::new();

    for attr in &cmd.attributes {
        props.insert(attr.name.clone(), attr_schema(agg, attr));
        if attr.required {
            required.push(json!(attr.name));
        }
    }
    // A declared reference is an id string ; the payload gate resolves it.
    for r in &cmd.references {
        props.insert(
            r.name.clone(),
            json!({ "type": "string", "description": format!("id of a {}", r.target) }),
        );
    }

    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": format!("{}.{}", agg.name, cmd.name),
        "type": "object",
        "properties": Value::Object(props),
        "required": required,
        "additionalProperties": false,
    })
}

/// Schema for one attribute : one_of → enum, wrapper VO → inner type,
/// member VO → enum of discriminants, else the mapped primitive. Public
/// so the served form renders from it — the ONE place that decides
/// enum-vs-type, shared by the form, external validators, and the MCP door.
pub fn attr_schema(agg: &Aggregate, attr: &Attribute) -> Value {
    // one_of scalar sugar — the closed vocabulary rides the attribute.
    if !attr.enum_values.is_empty() {
        return json!({ "type": "string", "enum": attr.enum_values });
    }
    // A value object referenced by type.
    if let Some(vo) = agg.value_objects.iter().find(|v| v.name == attr.attr_type) {
        // one_of members → enum of the first-attribute discriminants.
        if !vo.members.is_empty() {
            let discs: Vec<&str> = vo
                .members
                .iter()
                .filter_map(|m| m.first().map(|(_, v)| v.as_str()))
                .collect();
            return json!({ "type": "string", "enum": discs });
        }
        // Wrapper VO (single inner attribute) → its inner primitive,
        // enriched with minimum / maximum from any simple `>= N` / `<= N`
        // invariant — invariants that ARE schema keywords
        // (PLAN-json-schema-projection). The form renders these as the
        // number input's min / max, so a below-bound value can't be typed.
        if vo.attributes.len() == 1 {
            let mut schema = primitive_schema(&vo.attributes[0].attr_type);
            if let Some(obj) = schema.as_object_mut() {
                for inv in &vo.invariants {
                    for clause in inv.expression.split("&&") {
                        if let Some((_, rhs)) = clause.split_once(">=") {
                            if let Ok(n) = rhs.trim().parse::<i64>() {
                                obj.insert("minimum".into(), json!(n));
                            }
                        } else if let Some((_, rhs)) = clause.split_once("<=") {
                            if let Ok(n) = rhs.trim().parse::<i64>() {
                                obj.insert("maximum".into(), json!(n));
                            }
                        }
                    }
                }
                // Money convention : a wrapper whose inner field is `cents`
                // is minor-unit money (Pizzas' Price/Fee shape). The WIRE
                // stays cents — minimum too — so external validators and the
                // gate see the true integer contract ; the form reads this
                // hint to DISPLAY dollars and convert ×100 on submit.
                if vo.attributes[0].name == "cents" {
                    obj.insert("x-hecks-money".into(), json!("cents"));
                }
            }
            return schema;
        }
    }
    primitive_schema(&attr.attr_type)
}

fn primitive_schema(ty: &str) -> Value {
    match ty.to_lowercase().as_str() {
        "integer" | "int" => json!({ "type": "integer" }),
        "float" => json!({ "type": "number" }),
        "boolean" | "bool" => json!({ "type": "boolean" }),
        _ => json!({ "type": "string" }),
    }
}

/// Every command's schema for a domain, keyed by `Aggregate.Command`.
pub fn domain_schemas(domain: &crate::ir::Domain) -> Value {
    let mut map = Map::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            map.insert(format!("{}.{}", agg.name, cmd.name), command_schema(agg, cmd));
        }
    }
    Value::Object(map)
}
