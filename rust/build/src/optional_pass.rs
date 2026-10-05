//! Marks value-object and entity fields `optional` when an `append` mutation binds them to an
//! optional command argument, so the generated struct field is an `Option`.
//!
//! Resolves the appended element as `Hecks::RustBuild::AppendOptionals` does in Ruby: a local
//! entity wins over any value object of the same name, a local value object over a domain-wide one,
//! and an `append` into another aggregate's value object marks that value object.

use std::collections::HashMap;

use crate::json::Json;

/// Where an appended element lives: its aggregate's index, then its own index in that aggregate.
#[derive(Clone, Copy)]
enum Element {
    ValueObject(usize, usize),
    Entity(usize, usize),
}

struct Mark {
    element: Element,
    field: String,
}

pub fn run(ir: &mut Json) {
    let marks = collect_marks(ir);
    apply_marks(ir, &marks);
}

fn list<'a>(node: &'a Json, key: &str) -> &'a [Json] {
    node.get(key).map(Json::each).unwrap_or(&[])
}

fn name_of(node: &Json) -> Option<&str> {
    node.get("name").and_then(Json::as_str)
}

// Every value object in the domain by name; the last one declared wins, as a Ruby `to_h` does.
fn domain_wide_value_objects(aggregates: &[Json]) -> HashMap<&str, (usize, usize)> {
    let mut by_name = HashMap::new();
    for (a, aggregate) in aggregates.iter().enumerate() {
        for (v, value_object) in list(aggregate, "value_objects").iter().enumerate() {
            if let Some(name) = name_of(value_object) {
                by_name.insert(name, (a, v));
            }
        }
    }
    by_name
}

fn find_element(aggregates: &[Json], a: usize, domain_wide: &HashMap<&str, (usize, usize)>, type_name: &str) -> Option<Element> {
    let aggregate = &aggregates[a];
    if let Some(e) = list(aggregate, "entities").iter().position(|entity| name_of(entity) == Some(type_name)) {
        return Some(Element::Entity(a, e));
    }
    if let Some(v) = list(aggregate, "value_objects").iter().rposition(|value_object| name_of(value_object) == Some(type_name)) {
        return Some(Element::ValueObject(a, v));
    }
    domain_wide.get(type_name).map(|&(owner, v)| Element::ValueObject(owner, v))
}

// Read first, write after: the commands are read while the elements they mark are mutated.
fn collect_marks(ir: &Json) -> Vec<Mark> {
    let aggregates = list(ir, "aggregates");
    let domain_wide = domain_wide_value_objects(aggregates);
    let mut marks = Vec::new();

    for (a, aggregate) in aggregates.iter().enumerate() {
        for attribute in list(aggregate, "attributes") {
            let (Some(attr_name), Some(type_name)) = (name_of(attribute), attribute.get("type").and_then(Json::as_str)) else { continue };
            let Some(element) = find_element(aggregates, a, &domain_wide, type_name) else { continue };

            for field in collect_fields_to_mark(aggregate, attr_name) {
                marks.push(Mark { element, field });
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

            let Some(fields) = mutation.get("fields").and_then(Json::as_object) else { continue };
            for (field_name, source) in fields {
                // Only a Symbol (an argument name) renders with a leading `:` in `Literal.render`.
                let Some(source_text) = source.as_str() else { continue };
                let Some(arg_name) = source_text.strip_prefix(':') else { continue };

                let source_is_optional = command_attrs
                    .iter()
                    .any(|a| name_of(a) == Some(arg_name) && a.get("optional").map(Json::as_bool).unwrap_or(false));
                if source_is_optional {
                    out.push(field_name.clone());
                }
            }
        }
    }

    out
}

fn apply_marks(ir: &mut Json, marks: &[Mark]) {
    let Some(aggregates) = ir.get_mut("aggregates").and_then(Json::as_array_mut) else { return };

    for mark in marks {
        let (a, key, index) = match mark.element {
            Element::ValueObject(a, v) => (a, "value_objects", v),
            Element::Entity(a, e) => (a, "entities", e),
        };
        let element = aggregates.get_mut(a).and_then(|aggregate| aggregate.get_mut(key)).and_then(Json::as_array_mut).and_then(|elements| elements.get_mut(index));
        let Some(attrs) = element.and_then(|element| element.get_mut("attributes")).and_then(Json::as_array_mut) else { continue };

        if let Some(field_attr) = attrs.iter_mut().find(|a| name_of(a) == Some(mark.field.as_str())) {
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
        Json::parse(&format!(r#"{{"aggregates": [{}]}}"#, aggregates.join(","))).expect("fixture parses")
    }

    fn amount_optional(ir: &Json, aggregate: usize, key: &str) -> bool {
        let element = &list(&list(ir, "aggregates")[aggregate], key)[0];
        let amount = list(element, "attributes").iter().find(|a| name_of(a) == Some("amount")).unwrap();
        amount.get("optional").unwrap().as_bool()
    }

    // The input and expectation `spec/rust_build_generation_helpers_spec.rb` holds the Ruby pass to,
    // recorded from it. Read at test time, not compiled in: an installed gem has no `spec/`.
    #[test]
    fn marks_what_the_ruby_pass_marks_on_the_shared_fixture() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/fixtures/append_optionals");
        let read = |name: &str| Json::parse(&std::fs::read_to_string(dir.join(name)).expect("reads the fixture")).expect("parses");

        let mut ir = read("input.json");
        run(&mut ir);

        assert_eq!(ir, read("expected.json"));
    }

    // Banking's `Account.Credit` shape: entity list `ledger`, one `append` binding `amount` from
    // an optional argument and `direction` from a literal Hash.
    #[test]
    fn marks_the_argument_sourced_field_optional() {
        let mut ir = domain(&[aggregate_with(&element(false), "", "LedgerEntry")]);
        run(&mut ir);

        assert!(amount_optional(&ir, 0, "entities"));
    }

    #[test]
    fn marks_a_value_object_another_aggregate_declares() {
        let owner = r#"{"attributes": [], "value_objects": [LEDGER], "entities": [], "commands": []}"#.replace("LEDGER", &element(false));
        let appender = aggregate_with("", "", "LedgerEntry");
        let mut ir = domain(&[appender, owner]);
        run(&mut ir);

        assert!(amount_optional(&ir, 1, "value_objects"), "the value object lives in the second aggregate");
    }

    #[test]
    fn prefers_a_local_entity_over_a_value_object_of_the_same_name() {
        let local = aggregate_with(&element(false), "", "LedgerEntry");
        let owner = r#"{"attributes": [], "value_objects": [LEDGER], "entities": [], "commands": []}"#.replace("LEDGER", &element(false));
        let mut ir = domain(&[local, owner]);
        run(&mut ir);

        assert!(amount_optional(&ir, 0, "entities"), "the local entity is the one marked");
        assert!(!amount_optional(&ir, 1, "value_objects"), "the domain-wide value object is left alone");
    }

    #[test]
    fn leaves_a_field_alone_when_its_argument_is_required() {
        let mut ir = domain(&[aggregate_with(&element(false), "", "LedgerEntry").replace("\"optional\": true", "\"optional\": false")]);
        run(&mut ir);

        assert!(!amount_optional(&ir, 0, "entities"));
    }
}
