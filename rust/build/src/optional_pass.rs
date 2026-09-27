//! Marks value-object and entity fields `optional` when an `append` mutation binds them to an
//! optional command argument, so the generated struct field is an `Option`.

use crate::json::Json;

pub fn run(ir: &mut Json) {
    if let Some(aggregates) = ir.get_mut("aggregates").and_then(Json::as_array_mut) {
        for aggregate in aggregates.iter_mut() {
            mark_append_optional_fields(aggregate);
        }
    }
}

enum ElementRef {
    ValueObject(usize),
    Entity(usize),
}

fn find_element_ref(aggregate: &Json, target_type: &str) -> Option<ElementRef> {
    if let Some(idx) = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]).iter().position(|vo| vo.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(ElementRef::ValueObject(idx));
    }
    if let Some(idx) = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().position(|e| e.get("name").and_then(Json::as_str) == Some(target_type)) {
        return Some(ElementRef::Entity(idx));
    }
    None
}

// Gathers the fields to mark first, then applies them: the commands are read while the
// value objects and entities are mutated.
fn mark_append_optional_fields(aggregate: &mut Json) {
    let target_attrs: Vec<(String, String)> = aggregate
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter_map(|a| {
            let name = a.get("name").and_then(Json::as_str)?;
            let type_name = a.get("type").and_then(Json::as_str)?;
            Some((name.to_string(), type_name.to_string()))
        })
        .collect();

    for (attr_name, attr_type) in target_attrs {
        let Some(element_ref) = find_element_ref(aggregate, &attr_type) else { continue };

        let fields_to_mark = collect_fields_to_mark(aggregate, &attr_name);
        if fields_to_mark.is_empty() {
            continue;
        }

        apply_marks(aggregate, &element_ref, &fields_to_mark);
    }
}

fn collect_fields_to_mark(aggregate: &Json, target_attr_name: &str) -> Vec<String> {
    let mut out = Vec::new();

    for command in aggregate.get("commands").map(Json::each).unwrap_or(&[]) {
        let command_attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);

        for mutation in command.get("mutations").map(Json::each).unwrap_or(&[]) {
            let op = mutation.get("op").and_then(Json::as_str).unwrap_or("");
            let target = mutation.get("target").and_then(Json::as_str).unwrap_or("");
            if op != "append" || target != target_attr_name {
                continue;
            }

            let Some(fields) = mutation.get("fields").and_then(Json::as_object) else { continue };
            for (field_name, source) in fields {
                // Only a Symbol (an argument name) renders with a leading `:` in `Literal.render`.
                let Some(source_text) = source.as_str() else { continue };
                let Some(arg_name) = source_text.strip_prefix(':') else { continue };

                let source_is_optional = command_attrs.iter().any(|a| {
                    a.get("name").and_then(Json::as_str) == Some(arg_name) && a.get("optional").map(Json::as_bool).unwrap_or(false)
                });
                if source_is_optional {
                    out.push(field_name.clone());
                }
            }
        }
    }

    out
}

fn apply_marks(aggregate: &mut Json, element_ref: &ElementRef, fields_to_mark: &[String]) {
    let element = match element_ref {
        ElementRef::ValueObject(idx) => aggregate.get_mut("value_objects").and_then(Json::as_array_mut).and_then(|v| v.get_mut(*idx)),
        ElementRef::Entity(idx) => aggregate.get_mut("entities").and_then(Json::as_array_mut).and_then(|v| v.get_mut(*idx)),
    };
    let Some(element) = element else { return };
    let Some(attrs) = element.get_mut("attributes").and_then(Json::as_array_mut) else { return };

    for field_name in fields_to_mark {
        if let Some(field_attr) = attrs.iter_mut().find(|a| a.get("name").and_then(Json::as_str) == Some(field_name.as_str())) {
            field_attr.set_bool("optional", true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Banking's `Account.Credit` shape: entity list `ledger`, one `append` binding `amount` from
    // an optional argument and `direction` from a literal Hash.
    fn fixture() -> Json {
        Json::parse(
            r#"{
  "attributes": [
    {"name": "ledger", "type": "LedgerEntry", "list": true, "default": null, "optional": false, "pattern": null, "admits": null}
  ],
  "value_objects": [],
  "entities": [
    {
      "name": "LedgerEntry",
      "attributes": [
        {"name": "amount", "type": "Money", "list": false, "default": null, "optional": false, "pattern": null, "admits": null},
        {"name": "direction", "type": "Direction", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}
      ]
    }
  ],
  "commands": [
    {
      "name": "Credit",
      "attributes": [
        {"name": "amount", "type": "PositiveMoney", "list": false, "default": null, "optional": true, "pattern": null, "admits": null}
      ],
      "mutations": [
        {"target": "ledger", "op": "append", "fields": {"amount": ":amount", "direction": "{value: \"credit\"}"}}
      ]
    }
  ]
}"#,
        )
        .expect("fixture parses")
    }

    #[test]
    fn marks_the_argument_sourced_field_optional() {
        let mut aggregate = fixture();
        mark_append_optional_fields(&mut aggregate);

        let entity = &aggregate.get("entities").unwrap().each()[0];
        let amount = entity.get("attributes").unwrap().each().iter().find(|a| a.get("name").and_then(Json::as_str) == Some("amount")).unwrap();
        assert!(amount.get("optional").unwrap().as_bool());
    }
}
