//! Port of `rust/project/ports.rb` — read that file's own header comments
//! in full; this mirrors its algorithm directly, function for function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

/// A list attribute carrying `admits:`/`pattern:` used to be refused
/// here too (`constraint_list_problems`) — removed (docs/decisions/0051):
/// confirmed against Ruby's real dispatch pipeline that neither is ever
/// enforced on a list attribute regardless, so refusing to generate the
/// operation at all was MORE restrictive than Ruby, not a real gap.
pub fn port_operation_skip_reason(
    operation: &Json,
    _owner_name: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> Option<String> {
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
    let args_struct = format!(
        "{}{}Args",
        naming::rust_ident(port_name),
        naming::rust_ident(operation.get("name").and_then(Json::as_str).unwrap_or(""))
    );
    let qualified = format!("{domain_name}::{owner_name}");
    let attrs = operation.get("attributes").map(Json::each).unwrap_or(&[]);
    // A self-reference on a port operation is a migration-era spelling of
    // its receiver, never an external fact. Keep accepting old IR while
    // excluding that field from the typed args and event payload.
    let fact_attrs: Vec<Json> = attrs
        .iter()
        .filter(|attr| naming::reference_target(crate::attr::type_name(attr)) != Some(owner_name))
        .cloned()
        .collect();

    let mut struct_lines = vec![format!("pub struct {args_struct} {{")];
    for attr in &fact_attrs {
        let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
        if crate::attr::optional(attr) {
            ty = format!("Option<{ty}>");
        }
        struct_lines.push(format!(
            "    {}",
            exemplar.render(
                "struct_field",
                &[
                    ("TmplFieldType", ty),
                    (
                        "tmpl_field",
                        naming::rust_ident_field(crate::attr::name(attr))
                    )
                ]
            )
        ));
    }
    struct_lines.push("}".to_string());

    let invariant_checks = crate::commands::invariant_checks_for(
        exemplar,
        operation,
        aggregates_by_name,
        value_objects_by_name,
    );
    let fn_name = format!(
        "{}_{}",
        port_name.to_lowercase(),
        naming::dispatch_fn_name(&naming::rust_ident(
            operation.get("name").and_then(Json::as_str).unwrap_or("")
        ))
    );

    let emits = operation.get("emits").map(Json::each).unwrap_or(&[]);
    let events: Vec<String> = emits
        .iter()
        .map(|event_name| {
            format!(
                "        crate::kernel::Event {{ name: {}.to_string(), aggregate: {}.to_string(), id: receiver_id.to_string(), payload: crate::kernel::Json::Null, occurred_at: None, correlation: None }},",
                naming::ruby_inspect_string(&event_name.to_s()),
                naming::ruby_inspect_string(&qualified)
            )
        })
        .collect();

    let dispatch_fn = format!(
        "pub fn dispatch_operation_{fn_name}(receiver_id: &str, args: {args_struct}) -> Result<Vec<crate::kernel::Event>, crate::kernel::Refusal> {{\n{}\n    Ok(vec![\n{}\n    ])\n}}",
        invariant_checks.join("\n"),
        events.join("\n")
    );

    let operation_name = operation.get("name").and_then(Json::as_str).unwrap_or("");
    [
        format!("#[derive(Debug, Clone)]\n{}", struct_lines.join("\n")),
        crate::json_codec::emit_to_json_flat(exemplar, &args_struct, &fact_attrs, value_objects_by_name, false, &[], None),
        crate::json_codec::emit_from_json_flat(
            exemplar,
            &args_struct,
            &fact_attrs,
            value_objects_by_name,
            None,
            Some(&format!("{port_name}.{operation_name}")),
        ),
        dispatch_fn,
    ]
    .join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_receiver_is_not_a_port_fact_or_event_payload_field() {
        let operation = Json::parse(
            r#"{
              "name":"Receive",
              "attributes":[
                {"name":"order","type":"Reference<Order>","list":false,"optional":false},
                {"name":"amount","type":"Integer","list":false,"optional":false}
              ],
              "emits":["PaymentReceived"]
            }"#,
        )
        .unwrap();
        let value_objects = HashMap::new();
        let aggregates = HashMap::new();

        assert_eq!(
            port_operation_skip_reason(&operation, "Order", &value_objects),
            None
        );
        let generated = emit_port_operation(
            &Exemplar::load(),
            &operation,
            "PaymentGateway",
            "Order",
            "Pizzas",
            &value_objects,
            &aggregates,
        );

        assert!(generated.contains(
            "dispatch_operation_paymentgateway_receive(receiver_id: &str, args: PaymentGatewayReceiveArgs)"
        ));
        assert!(generated.contains("id: receiver_id.to_string()"));
        assert!(generated.contains("pub amount: i64"));
        assert!(!generated.contains("pub order:"));
        assert!(!generated.contains("v.require(\"order\""));
    }

    #[test]
    fn owner_operation_without_a_transitional_reference_is_generated() {
        let operation = Json::parse(
            r#"{
              "name":"Receive",
              "attributes":[{"name":"amount","type":"Integer","list":false,"optional":false}],
              "emits":["PaymentReceived"]
            }"#,
        )
        .unwrap();
        assert_eq!(
            port_operation_skip_reason(&operation, "Order", &HashMap::new()),
            None
        );
    }
}
