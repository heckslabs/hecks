//! Port of `rust/project/ports.rb` — read that file's own header comments
//! in full; this mirrors its algorithm directly, function for function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

pub fn port_operation_skip_reason(operation: &Json, owner_name: &str, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let constraint_problems = crate::commands::constraint_list_problems(operation);
    if !constraint_problems.is_empty() {
        return Some(constraint_problems.join("; "));
    }

    let attrs = operation.get("attributes").map(Json::each).unwrap_or(&[]);
    let unresolved: Vec<&Json> = attrs
        .iter()
        .filter(|attr| {
            if crate::attr::list(attr) {
                return false;
            }
            if naming::reference_type(crate::attr::type_name(attr)) {
                return false;
            }
            if naming::scalar_rust_type(crate::attr::type_name(attr)).is_some() {
                return false;
            }
            !value_objects_by_name.contains_key(crate::attr::type_name(attr))
        })
        .collect();
    if !unresolved.is_empty() {
        let mut types: Vec<&str> = Vec::new();
        for a in &unresolved {
            let t = crate::attr::type_name(a);
            if !types.contains(&t) {
                types.push(t);
            }
        }
        return Some(format!("attribute type(s) {} not generated yet (a value object this aggregate's own attributes never resolved a Rust type for)", types.join(", ")));
    }

    let identity_attr = attrs.iter().find(|attr| naming::reference_target(crate::attr::type_name(attr)) == Some(owner_name));
    if identity_attr.is_none() {
        return Some(format!(
            "names no reference_to {owner_name} — PortOperationBuilder#build should already have refused this at declare time, so reaching this is a codegen bug worth investigating, not a domain mistake"
        ));
    }

    None
}

/// ── ONE emitter per port operation.
pub fn emit_port_operation(
    exemplar: &Exemplar,
    operation: &Json,
    port_name: &str,
    owner_name: &str,
    domain_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
    aggregates_by_name: &HashMap<String, &Json>,
) -> String {
    let args_struct = format!("{}{}Args", naming::rust_ident(port_name), naming::rust_ident(operation.get("name").and_then(Json::as_str).unwrap_or("")));
    let qualified = format!("{domain_name}::{owner_name}");
    let attrs = operation.get("attributes").map(Json::each).unwrap_or(&[]);
    let identity_attr = attrs.iter().find(|attr| naming::reference_target(crate::attr::type_name(attr)) == Some(owner_name)).expect("port_operation_skip_reason should have caught a missing identity attribute");
    let identity_field = naming::rust_ident_field(crate::attr::name(identity_attr));

    let mut struct_lines = vec![format!("pub struct {args_struct} {{")];
    for attr in attrs {
        let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
        if crate::attr::optional(attr) {
            ty = format!("Option<{ty}>");
        }
        struct_lines.push(format!("    {}", exemplar.render("struct_field", &[("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))])));
    }
    struct_lines.push("}".to_string());

    let invariant_checks = crate::commands::invariant_checks_for(exemplar, operation, aggregates_by_name, value_objects_by_name);
    let fn_name = format!("{}_{}", port_name.to_lowercase(), naming::dispatch_fn_name(&naming::rust_ident(operation.get("name").and_then(Json::as_str).unwrap_or(""))));

    let emits = operation.get("emits").map(Json::each).unwrap_or(&[]);
    let events: Vec<String> = emits
        .iter()
        .map(|event_name| {
            format!(
                "        crate::kernel::Event {{ name: {}.to_string(), aggregate: {}.to_string(), id: args.{identity_field}.clone(), payload: crate::kernel::Json::Null, correlation: None }},",
                naming::ruby_inspect_string(&event_name.to_s()),
                naming::ruby_inspect_string(&qualified)
            )
        })
        .collect();

    let dispatch_fn = format!(
        "pub fn dispatch_operation_{fn_name}(args: {args_struct}) -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {{\n{}\n    Ok(vec![\n{}\n    ])\n}}",
        invariant_checks.join("\n"),
        events.join("\n")
    );

    let operation_name = operation.get("name").and_then(Json::as_str).unwrap_or("");
    [
        format!("#[derive(Debug, Clone)]\n{}", struct_lines.join("\n")),
        crate::json_codec::emit_to_json_flat(exemplar, &args_struct, attrs, false, &[], None),
        crate::json_codec::emit_from_json_flat(exemplar, &args_struct, attrs, None, Some(&format!("{port_name}.{operation_name}"))),
        dispatch_fn,
    ]
    .join("\n\n")
}
