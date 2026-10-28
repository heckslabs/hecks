//! The bare answer shape, generated: a port of Ruby's `Value.materialize_unwrapped`, emitted as
//! type-directed Rust over `crate::kernel::Json`.
//!
//! A single-attribute value object answers as its sole field's value, a multi-field one as an
//! object of its fields, each unwrapped the same way; a list maps item-wise and an entity's
//! fields are unwrapped. Stored state stays wrapped: this is only what a caller is answered with
//! (`group_by` rows, and the kernel's `{"present": answer}` input).

use crate::json::Json;
use crate::registry::AggregateEntry;
use std::collections::HashMap;

/// Emits an expression unwrapping the `Json` named `expr` as a `type_name` (a `list` of them
/// when `list`), resolving value objects in `value_objects_by_name` and entities in `aggregate`.
pub fn unwrap_json_expr(
    expr: &str,
    type_name: &str,
    list: bool,
    aggregate: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    Unwrapper {
        aggregate,
        value_objects_by_name,
    }
    .expr(expr, type_name, list, &mut Vec::new())
}

/// Emits `pub fn present(state) -> Json` for one aggregate's module: its state (or one of its
/// events' payloads) with every field it declares unwrapped, other keys passed through.
///
/// The fields are the aggregate's attributes and projected fields, then every aggregate and
/// entity command argument not already named, since an event payload carries a command's
/// arguments. A name declared with more than one type unwraps by whichever type's field names
/// the value's own keys fit, first declared first.
pub fn emit_aggregate_presenter(
    aggregate: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    let unwrapper = Unwrapper {
        aggregate,
        value_objects_by_name,
    };
    let arms: Vec<String> = presented_fields(aggregate)
        .iter()
        .map(|(name, candidates)| format!("{name:?} => {},", unwrapper.candidates("v", candidates)))
        .collect();
    if arms.is_empty() {
        return format!("{PRESENT_DOC}pub fn present(state: crate::kernel::Json) -> crate::kernel::Json {{\n    state\n}}\n");
    }
    let arms = arms.join(" ");
    format!(
        "{PRESENT_DOC}pub fn present(state: crate::kernel::Json) -> crate::kernel::Json {{\n    match state {{ crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(fields.into_iter().map(|(k, v)| {{ let new_v = match k.as_str() {{ {arms} _ => v }}; (k, new_v) }}).collect()), other => other }}\n}}\n"
    )
}

const PRESENT_DOC: &str = "/// This aggregate's state, or one of its events' payloads, as a caller is answered with\n/// it: each single-field value object as its bare field (the shape a command takes it in).\n";

/// Emits the merged target's `present(aggregate, state)`: one arm per generated aggregate across
/// every bluebook, keyed by its qualified `Domain::Aggregate` name; any other name passes through.
pub fn emit_present_router(aggregates: &[AggregateEntry]) -> String {
    let arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            format!(
                "        {} => crate::generated::{}::{}::present(state),",
                crate::naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name)),
                a.bluebook_mod,
                a.module_name
            )
        })
        .collect();
    format!(
        "/// One `\"Domain::Aggregate\"` state as a caller is answered with it (the kernel's\n/// `{{\"present\": answer}}` input); stored state stays wrapped. An unknown name passes through.\npub fn present(aggregate: &str, state: crate::kernel::Json) -> crate::kernel::Json {{\n    match aggregate {{\n{}\n        _ => state,\n    }}\n}}\n",
        arms.join("\n")
    )
}

// Each presented name with its distinct declared (type, list) pairs, in declaration order.
fn presented_fields(aggregate: &Json) -> Vec<(String, Vec<(String, bool)>)> {
    let mut attributes: Vec<Json> = aggregate
        .get("attributes")
        .map_or_default(Json::each)
        .to_vec();
    attributes.extend(crate::types::projected_field_pseudo_attributes(aggregate));
    let commands = aggregate
        .get("commands")
        .map_or_default(Json::each)
        .iter()
        .chain(
            aggregate
                .get("entities")
                .map_or_default(Json::each)
                .iter()
                .flat_map(|e| e.get("commands").map_or_default(Json::each)),
        );
    for command in commands {
        attributes.extend(
            command
                .get("attributes")
                .map_or_default(Json::each)
                .iter()
                .cloned(),
        );
    }

    let mut fields: Vec<(String, Vec<(String, bool)>)> = Vec::new();
    for attribute in &attributes {
        let name = crate::attr::name(attribute).to_string();
        let candidate = (
            crate::attr::type_name(attribute).to_string(),
            crate::attr::list(attribute),
        );
        match fields.iter_mut().find(|(n, _)| *n == name) {
            Some((_, candidates)) if !candidates.contains(&candidate) => candidates.push(candidate),
            Some(_) => {}
            None => fields.push((name, vec![candidate])),
        }
    }
    fields
}

struct Unwrapper<'a> {
    aggregate: &'a Json,
    value_objects_by_name: &'a HashMap<String, &'a Json>,
}

impl Unwrapper<'_> {
    // The declared fields of a value object or entity type, and whether it is a value object.
    fn fields_of(&self, type_name: &str) -> Option<(&[Json], bool)> {
        if let Some(vo) = self.value_objects_by_name.get(type_name) {
            return vo.get("attributes").map(|a| (Json::each(a), true));
        }
        self.aggregate
            .get("entities")
            .map_or_default(Json::each)
            .iter()
            .find(|e| e.get("name").map(Json::to_s).unwrap_or_default() == type_name)
            .and_then(|e| e.get("attributes").map(|a| (Json::each(a), false)))
    }

    // `seen` holds the types being expanded, so a type that contains itself stops there and
    // passes its nested value through rather than recursing without end.
    fn expr(&self, expr: &str, type_name: &str, list: bool, seen: &mut Vec<String>) -> String {
        if list {
            let inner = self.expr("item", type_name, false, seen);
            return format!("match {expr} {{ crate::kernel::Json::Array(items) => crate::kernel::Json::Array(items.into_iter().map(|item| {inner}).collect()), other => other }}");
        }
        let Some((fields_meta, is_value_object)) = self.fields_of(type_name) else {
            return expr.to_string();
        };
        if seen.iter().any(|s| s == type_name) {
            return expr.to_string();
        }
        seen.push(type_name.to_string());
        let out = if is_value_object && fields_meta.len() == 1 {
            let field = &fields_meta[0];
            let unwrapped = self.expr(
                "field_value",
                crate::attr::type_name(field),
                crate::attr::list(field),
                seen,
            );
            let field_name = crate::attr::name(field);
            format!("match {expr} {{ crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == {field_name:?}).map_or(crate::kernel::Json::Null, |(_, field_value)| {unwrapped}), other => other }}")
        } else {
            let inner_arms: Vec<String> = fields_meta
                .iter()
                .map(|f| {
                    let unwrapped =
                        self.expr("v", crate::attr::type_name(f), crate::attr::list(f), seen);
                    format!("{:?} => {unwrapped},", crate::attr::name(f))
                })
                .collect();
            let inner_arms = inner_arms.join(" ");
            format!("match {expr} {{ crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(fields.into_iter().map(|(k, v)| {{ let new_v = match k.as_str() {{ {inner_arms} _ => v }}; (k, new_v) }}).collect()), other => other }}")
        };
        seen.pop();
        out
    }

    // One declared type unwraps unconditionally; several are told apart by the value's keys.
    fn candidates(&self, expr: &str, candidates: &[(String, bool)]) -> String {
        if let [(type_name, list)] = candidates {
            return self.expr(expr, type_name, *list, &mut Vec::new());
        }
        let branches: Vec<String> = candidates
            .iter()
            .filter_map(|(type_name, list)| {
                let guard = self.fits(&format!("&{expr}"), type_name, *list)?;
                let unwrapped = self.expr(expr, type_name, *list, &mut Vec::new());
                Some(format!("if {guard} {{ {unwrapped} }}"))
            })
            .collect();
        if branches.is_empty() {
            return expr.to_string();
        }
        format!("{} else {{ {expr} }}", branches.join(" else "))
    }

    // Whether the value at `expr` (a `&Json`) has the shape of `type_name`: an object whose keys
    // are all its declared fields. `None` for a type with no fields to unwrap.
    fn fits(&self, expr: &str, type_name: &str, list: bool) -> Option<String> {
        if list {
            let item = self.fits("item", type_name, false)?;
            return Some(format!("matches!({expr}, crate::kernel::Json::Array(items) if items.iter().all(|item| {item}))"));
        }
        let (fields_meta, _) = self.fields_of(type_name)?;
        let names: Vec<String> = fields_meta
            .iter()
            .map(|f| format!("{:?}", crate::attr::name(f)))
            .collect();
        Some(format!("matches!({expr}, crate::kernel::Json::Object(fields) if fields.iter().all(|(k, _)| matches!(k.as_str(), {})))", names.join(" | ")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attribute(name: &str, type_name: &str, list: bool) -> String {
        format!(r#"{{"name": "{name}", "type": "{type_name}", "list": {list}}}"#)
    }

    fn value_object(name: &str, attributes: &[String]) -> String {
        format!(
            r#"{{"name": "{name}", "attributes": [{}]}}"#,
            attributes.join(", ")
        )
    }

    // Pizzas' `Order`, cut down: a single-field name, a multi-field pizza holding two
    // single-field value objects, a list of single-field tags, and two commands that both
    // take an `amount` of a different single-field type.
    fn order() -> Json {
        let text = format!(
            r#"{{"name": "Order",
                "attributes": [{}, {}, {}],
                "value_objects": [{}, {}, {}, {}, {}, {}],
                "commands": [
                  {{"name": "CreatePizza", "attributes": [{}, {}]}},
                  {{"name": "AddTopping", "attributes": [{}]}},
                  {{"name": "Purchase", "attributes": [{}]}}
                ]}}"#,
            attribute("name", "PizzaName", false),
            attribute("pizza", "Pizza", false),
            attribute("tags", "Tag", true),
            value_object("PizzaName", &[attribute("value", "String", false)]),
            value_object("Price", &[attribute("cents", "Integer", false)]),
            value_object("Size", &[attribute("value", "String", false)]),
            value_object("Tag", &[attribute("value", "String", false)]),
            value_object("ToppingAmount", &[attribute("value", "Integer", false)]),
            value_object(
                "Pizza",
                &[
                    attribute("price_cents", "Price", false),
                    attribute("size", "Size", false)
                ]
            ),
            attribute("name", "PizzaName", false),
            attribute("pizza", "Pizza", false),
            attribute("amount", "ToppingAmount", false),
            attribute("amount", "Price", false),
        );
        Json::parse(&text).unwrap()
    }

    fn presenter() -> String {
        let order = order();
        let vos: Vec<&Json> = order
            .get("value_objects")
            .map_or_default(Json::each)
            .iter()
            .collect();
        let by_name: HashMap<String, &Json> = vos
            .iter()
            .map(|vo| (vo.get("name").map(Json::to_s).unwrap_or_default(), *vo))
            .collect();
        emit_aggregate_presenter(&order, &by_name)
    }

    #[test]
    fn a_single_field_attribute_presents_as_its_sole_field() {
        assert!(presenter().contains(r#""name" => match v { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == "value")"#));
    }

    #[test]
    fn a_multi_field_value_object_keeps_its_object_and_unwraps_each_field() {
        let text = presenter();
        assert!(text.contains(r#""pizza" => match v { crate::kernel::Json::Object(fields) => crate::kernel::Json::Object("#));
        assert!(text.contains(r#""price_cents" => match v { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == "cents")"#));
        assert!(text.contains(r#""size" => match v { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == "value")"#));
    }

    #[test]
    fn a_list_of_single_field_value_objects_maps_item_wise() {
        assert!(presenter().contains(r#""tags" => match v { crate::kernel::Json::Array(items) => crate::kernel::Json::Array(items.into_iter().map(|item| match item { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == "value")"#));
    }

    #[test]
    fn a_name_declared_with_two_types_is_told_apart_by_its_keys() {
        let text = presenter();
        let arm = text.split(r#""amount" => "#).nth(1).unwrap();
        assert!(arm.starts_with(r#"if matches!(&v, crate::kernel::Json::Object(fields) if fields.iter().all(|(k, _)| matches!(k.as_str(), "value")))"#));
        assert!(arm.contains(r#"else if matches!(&v, crate::kernel::Json::Object(fields) if fields.iter().all(|(k, _)| matches!(k.as_str(), "cents")))"#));
    }

    #[test]
    fn a_command_argument_already_named_by_an_attribute_adds_no_second_arm() {
        assert_eq!(presenter().matches(r#""name" => "#).count(), 1);
    }

    #[test]
    fn the_router_names_each_aggregate_qualified_and_passes_any_other_through() {
        let entry = AggregateEntry {
            name: "Order".to_string(),
            module_name: "order".to_string(),
            record: "Order".to_string(),
            commands: vec![],
            entity_commands: vec![],
            nested_entity_commands: vec![],
            ports: vec![],
            bluebook_mod: "pizzas".to_string(),
            domain_name: "Pizzas".to_string(),
            reference_specs: vec![],
            identified_by: vec![],
            entities: vec![],
        };
        let text = emit_present_router(&[entry]);
        assert!(
            text.contains(r#""Pizzas::Order" => crate::generated::pizzas::order::present(state),"#)
        );
        assert!(text.contains("_ => state,"));
    }
}
