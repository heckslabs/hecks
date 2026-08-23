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

    let arms: Vec<String> = arms.iter().map(|a| format!("            {a}")).collect();

    format!("{}\n", exemplar.render("fielded_record", &[("TmplRecordType", name), ("\"tmpl_arms_placeholder\" => tmpl_arms_block(),", arms.join("\n"))]))
}
