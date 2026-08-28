//! Port of `rust/project/fielded.rb` — `emit_fielded_flat`/
//! `emit_fielded_record`, mirrored directly. Read the Ruby file's own
//! header for the six/seven leaf shapes this walks.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

fn is_fielded_nested(attr_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    match value_objects_by_name.get(attr_type) {
        Some(vo) => naming::fielded_capable_nested(vo),
        None => false,
    }
}

pub fn emit_fielded_flat(exemplar: &Exemplar, struct_name: &str, attributes: &[Json], value_objects_by_name: &HashMap<String, &Json>, extra_arms: &[String]) -> String {
    let mut arms: Vec<String> = Vec::new();

    for attr in attributes {
        let key = naming::rust_field(crate::attr::name(attr));
        let ident = naming::rust_ident_field(crate::attr::name(attr));
        let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
        let list = crate::attr::list(attr);
        let optional = crate::attr::optional(attr);

        let arm = if list && optional {
            Some(exemplar.render("fielded_arm_list_optional", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else if list {
            Some(exemplar.render("fielded_arm_list", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else if optional && scalar.is_some() {
            let scalar = scalar.unwrap();
            Some(exemplar.render(
                "fielded_arm_optional_scalar",
                &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident.clone()), ("tmpl_value_expr_placeholder(v)", naming::scalar_to_value(scalar, "v").unwrap())],
            ))
        } else if optional {
            if is_fielded_nested(crate::attr::type_name(attr), value_objects_by_name) {
                Some(exemplar.render("fielded_arm_optional_nested", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
            } else {
                None
            }
        } else if let Some(scalar) = scalar {
            Some(exemplar.render(
                "fielded_arm_scalar",
                &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_value_expr_placeholder(&self.tmpl_ident)", naming::scalar_to_value(scalar, &format!("self.{ident}")).unwrap())],
            ))
        } else if is_fielded_nested(crate::attr::type_name(attr), value_objects_by_name) {
            Some(exemplar.render("fielded_arm_nested", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else {
            None
        };

        if let Some(a) = arm {
            arms.push(a);
        }
    }

    let mut arms: Vec<String> = arms.iter().map(|a| format!("            {a}")).collect();
    arms.extend(extra_arms.iter().cloned());
    // `arms.any? { |arm| arm.include?('Value') }` — checked against the
    // FULL, already-assembled arm list (declared arms + extra_arms
    // together), not tracked incrementally per branch while building —
    // found live, byte-diffing against Ruby's real output: a plain
    // scalar arm (`fielded_arm_scalar`) ALSO emits `Value::...` text, and
    // an incremental per-branch tracker that only flagged the list/
    // optional branches (this function's own first draft) missed it.
    let uses_value = arms.iter().any(|a| a.contains("Value"));

    format!(
        "{}\n",
        exemplar.render(
            "fielded_flat",
            &[
                ("TmplFlatType", struct_name.to_string()),
                ("\"tmpl_arms_placeholder\" => tmpl_arms_block(),", arms.join("\n")),
                ("\"tmpl_items_placeholder\" => tmpl_items_block(),", items_arms(exemplar, attributes, value_objects_by_name, &[], |attr| crate::attr::optional(attr)).join("\n")),
                ("tmpl_as_scalar_placeholder()", as_scalar_expr(attributes)),
                ("use crate::kernel::Value;", if uses_value { "use crate::kernel::Value;".to_string() } else { String::new() }),
            ],
        )
    )
}

pub fn emit_fielded_record(exemplar: &Exemplar, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let mut arms: Vec<String> = Vec::new();

    for attr in attributes {
        let key = naming::rust_field(crate::attr::name(attr));
        let ident = naming::rust_ident_field(crate::attr::name(attr));
        let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
        let list = crate::attr::list(attr);

        let arm = if list && crate::shared::list_attr_creation_optional(aggregate, crate::attr::name(attr), value_objects_by_name) {
            Some(exemplar.render("fielded_arm_list_optional", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else if list {
            Some(exemplar.render("fielded_arm_list", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else if let Some(scalar) = scalar {
            Some(exemplar.render(
                "fielded_arm_optional_scalar",
                &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident.clone()), ("tmpl_value_expr_placeholder(v)", naming::scalar_to_value(scalar, "v").unwrap())],
            ))
        } else if is_fielded_nested(crate::attr::type_name(attr), value_objects_by_name) {
            Some(exemplar.render("fielded_arm_optional_nested", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]))
        } else {
            None
        };

        if let Some(a) = arm {
            arms.push(a);
        }
    }

    if let Some(lifecycle) = aggregate.get("lifecycle") {
        let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("");
        let key = naming::rust_field(field);
        let ident = naming::rust_ident_field(field);
        arms.push(exemplar.render("fielded_lifecycle_arm", &[("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)]));
    }
    for ev in crate::bridging::correctable_event_names(aggregate) {
        let ident = crate::bridging::corrects_flag_field(&ev);
        arms.push(exemplar.render("fielded_corrects_flag_arm", &[("\"tmpl_field\"", naming::ruby_inspect_string(&ident)), ("tmpl_ident", ident)]));
    }

    let arms: Vec<String> = arms.iter().map(|a| format!("            {a}")).collect();

    let entity_names: Vec<String> = aggregate
        .get("entities")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter_map(|e| e.get("name").and_then(Json::as_str).map(str::to_string))
        .collect();
    let items = items_arms(exemplar, attributes, value_objects_by_name, &entity_names, |attr| {
        crate::shared::list_attr_creation_optional(aggregate, crate::attr::name(attr), value_objects_by_name)
    });

    format!(
        "{}\n",
        exemplar.render(
            "fielded_record",
            &[
                ("TmplRecordType", name),
                ("\"tmpl_arms_placeholder\" => tmpl_arms_block(),", arms.join("\n")),
                ("\"tmpl_items_placeholder\" => tmpl_items_block(),", items.join("\n")),
                ("tmpl_as_scalar_placeholder()", as_scalar_expr(attributes)),
            ],
        )
    )
}

/// Port of fielded.rb's `as_scalar_expr` — `Resolver#unwrap_scalar`: a
/// struct with exactly ONE attribute reads as that attribute's value,
/// whatever it is named (single-element value objects strictly answer
/// `.value` — relaxed from the old name-gated `== "value"` check in
/// lockstep with the Ruby projector and the Ruby oracle's own
/// `unwrap_scalar`; see fielded.rb's `as_scalar_expr` for the full
/// account). Only a genuine SCALAR leaf unwraps — a sole attribute
/// that is itself a value object already answered `None` through the
/// match's own `_` floor, so gating on `effective_scalar_type` changes
/// no runtime answer; it emits the honest literal `None` instead of a
/// match that could never bind (fielded.rb's own `as_scalar_expr`
/// comment, and spec/rust_project/closed_set_fielded_spec.rb's pin).
fn as_scalar_expr(attributes: &[Json]) -> String {
    let sole = attributes.len() == 1
        && !crate::attr::list(&attributes[0])
        && naming::effective_scalar_type(crate::attr::type_name(&attributes[0])).is_some();
    if sole {
        format!(
            "match self.field(\"{}\") {{ Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }}",
            naming::rust_field(crate::attr::name(&attributes[0]))
        )
    } else {
        "None".to_string()
    }
}

/// Port of `fielded.rb`'s `items_arms` — `Fielded::items`, one arm per
/// list attribute whose element is a scalar or a `Fielded` value object/
/// entity; anything else stays a length-only field with no arm.
fn items_arms(exemplar: &Exemplar, attributes: &[Json], value_objects_by_name: &HashMap<String, &Json>, entity_names: &[String], optional: impl Fn(&Json) -> bool) -> Vec<String> {
    let mut arms = Vec::new();
    for attr in attributes {
        if !crate::attr::list(attr) {
            continue;
        }
        let key = naming::rust_field(crate::attr::name(attr));
        let ident = naming::rust_ident_field(crate::attr::name(attr));
        let type_name = crate::attr::type_name(attr);
        let scalar = naming::effective_scalar_type(type_name);
        let fielded_element = scalar.is_some() || is_fielded_nested(type_name, value_objects_by_name) || entity_names.iter().any(|e| e == type_name);
        if !fielded_element {
            continue;
        }
        let shape = format!("fielded_items_arm_list_{}{}", if optional(attr) { "optional_" } else { "" }, if scalar.is_some() { "scalar" } else { "nested" });
        let mut subs: Vec<(&str, String)> = vec![("\"tmpl_field\"", naming::ruby_inspect_string(&key)), ("tmpl_ident", ident)];
        if let Some(scalar) = scalar {
            subs.push(("tmpl_value_expr_placeholder(v)", naming::scalar_to_value(scalar, "v").unwrap()));
        }
        arms.push(format!("            {}", exemplar.render(&shape, &subs)));
    }
    arms
}
