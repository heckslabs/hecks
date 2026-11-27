//! Marks entity fields `optional` when an `append` mutation binds them to an optional command
//! argument, so the generated struct field is an `Option` that can hold the absent argument.
//!
//! Only an entity is marked. Ruby builds an appended entity's fields as plain state, so an absent
//! optional argument leaves its field `nil`. An appended value object is built through
//! `Value.build`, which refuses a required field left `nil` with `TypeMismatch`; its declared shape
//! stands, and the generated append refuses the absent argument instead (`append_field_rhs`). The
//! appended element resolves as `mutations::append_element` resolves it: a local entity first.

use crate::json::Json;

/// A field to mark: the aggregate's index, the entity's index in it, and the field's name.
struct Mark {
    aggregate: usize,
    entity: usize,
    field: String,
}

pub fn run(ir: &mut Json) {
    let marks = collect_marks(ir);
    apply_marks(ir, &marks);
}

fn list<'a>(node: &'a Json, key: &str) -> &'a [Json] {
    node.get(key).map_or_default(Json::each)
}

fn name_of(node: &Json) -> Option<&str> {
    node.get("name").and_then(Json::as_str)
}

// Read first, write after: the commands are read while the entities they mark are mutated.
fn collect_marks(ir: &Json) -> Vec<Mark> {
    let mut marks = Vec::new();

    for (a, aggregate) in list(ir, "aggregates").iter().enumerate() {
        for attribute in list(aggregate, "attributes") {
            let (Some(attr_name), Some(type_name)) = (
                name_of(attribute),
                attribute.get("type").and_then(Json::as_str),
            ) else {
                continue;
            };
            let Some(entity) = list(aggregate, "entities")
                .iter()
                .position(|entity| name_of(entity) == Some(type_name))
            else {
                continue;
            };

            for field in collect_fields_to_mark(aggregate, attr_name) {
                marks.push(Mark {
                    aggregate: a,
                    entity,
                    field,
                });
            }
        }
    }
    marks
}

fn collect_fields_to_mark(aggregate: &Json, target_attr_name: &str) -> Vec<String> {
    let mut out = Vec::new();

    for command in list(aggregate, "commands") {
        let command_attrs = list(command, "attributes");

        for mutation in list(command, "mutations") {
            let op = mutation.get("op").and_then(Json::as_str).unwrap_or("");
            let target = mutation.get("target").and_then(Json::as_str).unwrap_or("");
            if op != "append" || target != target_attr_name {
                continue;
            }

            let Some(fields) = mutation.get("fields").and_then(Json::as_object) else {
                continue;
            };
            for (field_name, source) in fields {
                // Only a Symbol (an argument name) renders with a leading `:` in `Literal.render`.
                let Some(source_text) = source.as_str() else {
                    continue;
                };
                let Some(arg_name) = source_text.strip_prefix(':') else {
                    continue;
                };

                let source_is_optional = command_attrs.iter().any(|a| {
                    name_of(a) == Some(arg_name) && a.get("optional").is_some_and(Json::as_bool)
                });
                if source_is_optional {
                    out.push(field_name.clone());
                }
            }
        }
    }

    out
}

fn apply_marks(ir: &mut Json, marks: &[Mark]) {
    let Some(aggregates) = ir.get_mut("aggregates").and_then(Json::as_array_mut) else {
        return;
    };

    for mark in marks {
        let Some(attrs) = aggregates
            .get_mut(mark.aggregate)
            .and_then(|aggregate| aggregate.get_mut("entities"))
            .and_then(Json::as_array_mut)
            .and_then(|entities| entities.get_mut(mark.entity))
            .and_then(|entity| entity.get_mut("attributes"))
            .and_then(Json::as_array_mut)
        else {
            continue;
        };

        if let Some(field_attr) = attrs
            .iter_mut()
            .find(|a| name_of(a) == Some(mark.field.as_str()))
        {
            field_attr.set_bool("optional", true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn aggregate_with(entities: &str, value_objects: &str, attribute_type: &str) -> String {
        format!(
            r#"{{
  "attributes": [
    {{"name": "ledger", "type": "{attribute_type}", "list": true, "default": null, "optional": false, "pattern": null, "admits": null}}
  ],
  "value_objects": [{value_objects}],
  "entities": [{entities}],
  "commands": [
    {{
      "name": "Credit",
      "attributes": [
        {{"name": "amount", "type": "PositiveMoney", "list": false, "default": null, "optional": true, "pattern": null, "admits": null}}
      ],
      "mutations": [
        {{"target": "ledger", "op": "append", "fields": {{"amount": ":amount", "direction": "{{value: \"credit\"}}"}}}}
      ]
    }}
  ]
}}"#
        )
    }

    fn element(amount_optional: bool) -> String {
        format!(
            r#"{{"name": "LedgerEntry", "attributes": [
        {{"name": "amount", "type": "Money", "list": false, "default": null, "optional": {amount_optional}, "pattern": null, "admits": null}},
        {{"name": "direction", "type": "Direction", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}}
      ]}}"#
        )
    }

    fn domain(aggregates: &[String]) -> Json {
        Json::parse(&format!(r#"{{"aggregates": [{}]}}"#, aggregates.join(",")))
            .expect("fixture parses")
    }

    fn amount_optional(ir: &Json, aggregate: usize, key: &str) -> bool {
        let element = &list(&list(ir, "aggregates")[aggregate], key)[0];
        let amount = list(element, "attributes")
            .iter()
            .find(|a| name_of(a) == Some("amount"))
            .unwrap();
        amount.get("optional").unwrap().as_bool()
    }

    // Banking's `Account.Credit` shape: entity list `ledger`, one `append` binding `amount` from
    // an optional argument and `direction` from a literal Hash.
    #[test]
    fn marks_the_argument_sourced_field_optional() {
        let mut ir = domain(&[aggregate_with(&element(false), "", "LedgerEntry")]);
        run(&mut ir);

        assert!(amount_optional(&ir, 0, "entities"));
    }

    // `Bluebook.Normalise`'s shape: an optional argument appended into a value object whose field
    // is required. Ruby refuses the absent argument when it builds the value object, so the field
    // keeps its declared shape.
    #[test]
    fn leaves_a_value_object_field_as_declared() {
        let local = aggregate_with("", &element(false), "LedgerEntry");
        let mut ir = domain(&[local]);
        run(&mut ir);

        assert!(!amount_optional(&ir, 0, "value_objects"));
    }

    #[test]
    fn leaves_a_value_object_another_aggregate_declares_as_declared() {
        let owner =
            r#"{"attributes": [], "value_objects": [LEDGER], "entities": [], "commands": []}"#
                .replace("LEDGER", &element(false));
        let appender = aggregate_with("", "", "LedgerEntry");
        let mut ir = domain(&[appender, owner]);
        run(&mut ir);

        assert!(!amount_optional(&ir, 1, "value_objects"));
    }

    #[test]
    fn prefers_a_local_entity_over_a_value_object_of_the_same_name() {
        let local = aggregate_with(&element(false), "", "LedgerEntry");
        let owner =
            r#"{"attributes": [], "value_objects": [LEDGER], "entities": [], "commands": []}"#
                .replace("LEDGER", &element(false));
        let mut ir = domain(&[local, owner]);
        run(&mut ir);

        assert!(
            amount_optional(&ir, 0, "entities"),
            "the local entity is the one marked"
        );
        assert!(
            !amount_optional(&ir, 1, "value_objects"),
            "the domain-wide value object is left alone"
        );
    }

    #[test]
    fn leaves_a_field_alone_when_its_argument_is_required() {
        let mut ir = domain(&[aggregate_with(&element(false), "", "LedgerEntry")
            .replace("\"optional\": true", "\"optional\": false")]);
        run(&mut ir);

        assert!(!amount_optional(&ir, 0, "entities"));
    }
}
