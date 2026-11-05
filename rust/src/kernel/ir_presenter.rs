//! The bare answer shape, interpreted from a domain's canonical IR (ADR 0011, 0027).
//!
//! The same rule `rust/codegen/src/presenters.rs` emits as generated Rust, read from the IR at
//! run time instead: a single-attribute value object answers as its sole field's value, a
//! multi-field one as an object of its fields, each unwrapped the same way; a list maps
//! item-wise and an entity's fields are unwrapped. Stored state stays wrapped.
//!
//! A host passes the IR under the `{"present": answer}` input's `"ir"` key (one domain object, or
//! an array of them). Without it the kernel falls back to the generated router, so this is the
//! first slice of dropping `generated::active`, not the whole of it.

use super::Json;

/// One declared attribute: its name, type name, and whether it is a list.
#[derive(Clone, PartialEq)]
struct Field {
    name: String,
    type_name: String,
    list: bool,
}

/// A value object or entity type: its fields, and whether it is a value object.
struct Shape {
    name: String,
    fields: Vec<Field>,
    value_object: bool,
}

/// One aggregate's presented names, each with its distinct declared types, in declaration order.
struct AggregatePresenter {
    qualified: String,
    shapes: Vec<Shape>,
    names: Vec<(String, Vec<(String, bool)>)>,
}

/// Every aggregate of the IR it was built from, keyed by its `Domain::Aggregate` name.
pub struct IrPresenter {
    aggregates: Vec<AggregatePresenter>,
}

fn field_of(attribute: &Json) -> Option<Field> {
    Some(Field {
        name: attribute.get("name")?.as_str()?.to_string(),
        type_name: attribute
            .get("type")
            .and_then(Json::as_str)
            .unwrap_or("String")
            .to_string(),
        list: matches!(attribute.get("list"), Some(Json::Bool(true))),
    })
}

fn fields_in(object: &Json, key: &str) -> Vec<Field> {
    object
        .get(key)
        .and_then(Json::as_array)
        .map(|items| items.iter().filter_map(field_of).collect())
        .unwrap_or_default()
}

fn items<'a>(object: &'a Json, key: &str) -> &'a [Json] {
    object.get(key).and_then(Json::as_array).unwrap_or(&[])
}

impl IrPresenter {
    /// Reads one domain's IR, or an array of them.
    pub fn from_ir(ir: &Json) -> Self {
        let domains: &[Json] = match ir {
            Json::Array(domains) => domains,
            one => std::slice::from_ref(one),
        };
        let mut aggregates = Vec::new();
        for domain in domains {
            let domain_name = domain.get("name").and_then(Json::as_str).unwrap_or("");
            for aggregate in items(domain, "aggregates") {
                if let Some(built) = Self::aggregate(domain_name, aggregate) {
                    aggregates.push(built);
                }
            }
        }
        Self { aggregates }
    }

    fn aggregate(domain: &str, aggregate: &Json) -> Option<AggregatePresenter> {
        let name = aggregate.get("name")?.as_str()?;
        let mut shapes: Vec<Shape> = items(aggregate, "value_objects")
            .iter()
            .filter_map(|vo| {
                Some(Shape {
                    name: vo.get("name")?.as_str()?.to_string(),
                    fields: fields_in(vo, "attributes"),
                    value_object: true,
                })
            })
            .collect();
        for entity in items(aggregate, "entities") {
            if let Some(entity_name) = entity.get("name").and_then(Json::as_str) {
                shapes.push(Shape {
                    name: entity_name.to_string(),
                    fields: fields_in(entity, "attributes"),
                    value_object: false,
                });
            }
        }

        // The aggregate's attributes and projected fields, then every aggregate and entity
        // command argument, since an event payload carries a command's arguments.
        let mut declared = fields_in(aggregate, "attributes");
        declared.extend(items(aggregate, "projected_fields").iter().filter_map(|p| {
            Some(Field {
                name: p.get("name")?.as_str()?.to_string(),
                type_name: p
                    .get("type")
                    .and_then(Json::as_str)
                    .unwrap_or("String")
                    .to_string(),
                list: false,
            })
        }));
        let entity_commands = items(aggregate, "entities")
            .iter()
            .flat_map(|e| items(e, "commands"));
        for command in items(aggregate, "commands").iter().chain(entity_commands) {
            declared.extend(fields_in(command, "attributes"));
        }

        let mut names: Vec<(String, Vec<(String, bool)>)> = Vec::new();
        for field in declared {
            let candidate = (field.type_name, field.list);
            match names.iter_mut().find(|(n, _)| *n == field.name) {
                Some((_, candidates)) if !candidates.contains(&candidate) => {
                    candidates.push(candidate);
                }
                Some(_) => {}
                None => names.push((field.name, vec![candidate])),
            }
        }
        Some(AggregatePresenter {
            qualified: format!("{domain}::{name}"),
            shapes,
            names,
        })
    }

    /// One `"Domain::Aggregate"` state as a caller is answered with it; an unknown name passes
    /// through, as the generated router does.
    pub fn present(&self, aggregate: &str, state: Json) -> Json {
        match self.aggregates.iter().find(|a| a.qualified == aggregate) {
            Some(found) => found.present(state),
            None => state,
        }
    }
}

impl AggregatePresenter {
    fn shape(&self, type_name: &str) -> Option<&Shape> {
        self.shapes.iter().find(|s| s.name == type_name)
    }

    fn present(&self, state: Json) -> Json {
        if self.names.is_empty() {
            return state;
        }
        let Json::Object(fields) = state else {
            return state;
        };
        Json::Object(
            fields
                .into_iter()
                .map(|(key, value)| {
                    let value = match self.names.iter().find(|(n, _)| *n == key) {
                        Some((_, candidates)) => self.candidates(value, candidates),
                        None => value,
                    };
                    (key, value)
                })
                .collect(),
        )
    }

    // One declared type unwraps unconditionally; several are told apart by the value's keys.
    fn candidates(&self, value: Json, candidates: &[(String, bool)]) -> Json {
        if let [(type_name, list)] = candidates {
            return self.unwrap(value, type_name, *list, &mut Vec::new());
        }
        for (type_name, list) in candidates {
            if self.fits(&value, type_name, *list) == Some(true) {
                return self.unwrap(value, type_name, *list, &mut Vec::new());
            }
        }
        value
    }

    // Whether `value` has the shape of `type_name`: an object whose keys are all its declared
    // fields. `None` for a type with no fields to unwrap.
    fn fits(&self, value: &Json, type_name: &str, list: bool) -> Option<bool> {
        if list {
            self.shape(type_name)?;
            return Some(match value {
                Json::Array(items) => items
                    .iter()
                    .all(|item| self.fits(item, type_name, false) == Some(true)),
                _ => false,
            });
        }
        let shape = self.shape(type_name)?;
        Some(match value {
            Json::Object(fields) => fields
                .iter()
                .all(|(k, _)| shape.fields.iter().any(|f| f.name == *k)),
            _ => false,
        })
    }

    // `seen` holds the types being expanded, so a type that contains itself stops there and
    // passes its nested value through rather than recursing without end.
    fn unwrap(&self, value: Json, type_name: &str, list: bool, seen: &mut Vec<String>) -> Json {
        if list {
            return match value {
                Json::Array(items) => Json::Array(
                    items
                        .into_iter()
                        .map(|item| self.unwrap(item, type_name, false, seen))
                        .collect(),
                ),
                other => other,
            };
        }
        let Some(shape) = self.shape(type_name) else {
            return value;
        };
        if seen.iter().any(|s| s == type_name) {
            return value;
        }
        seen.push(type_name.to_string());
        let out = if shape.value_object && shape.fields.len() == 1 {
            let field = &shape.fields[0];
            match value {
                Json::Object(fields) => fields
                    .into_iter()
                    .find(|(k, _)| *k == field.name)
                    .map_or(Json::Null, |(_, inner)| {
                        self.unwrap(inner, &field.type_name, field.list, seen)
                    }),
                other => other,
            }
        } else {
            match value {
                Json::Object(fields) => Json::Object(
                    fields
                        .into_iter()
                        .map(|(k, v)| {
                            let v = match shape.fields.iter().find(|f| f.name == k) {
                                Some(f) => self.unwrap(v, &f.type_name, f.list, seen),
                                None => v,
                            };
                            (k, v)
                        })
                        .collect(),
                ),
                other => other,
            }
        };
        seen.pop();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pizzas' `Order`, cut down: a single-field name, a multi-field pizza holding two
    // single-field value objects, a list of single-field tags, and two commands that both take
    // an `amount` of a different single-field type.
    const IR: &str = r#"{"name": "Pizzas", "aggregates": [{"name": "Order",
        "attributes": [{"name": "name", "type": "PizzaName"}, {"name": "pizza", "type": "Pizza"},
                       {"name": "tags", "type": "Tag", "list": true}],
        "value_objects": [
          {"name": "PizzaName", "attributes": [{"name": "value", "type": "String"}]},
          {"name": "Price", "attributes": [{"name": "cents", "type": "Integer"}]},
          {"name": "Size", "attributes": [{"name": "value", "type": "String"}]},
          {"name": "Tag", "attributes": [{"name": "value", "type": "String"}]},
          {"name": "ToppingAmount", "attributes": [{"name": "value", "type": "Integer"}]},
          {"name": "Pizza", "attributes": [{"name": "price_cents", "type": "Price"},
                                           {"name": "size", "type": "Size"}]}],
        "commands": [
          {"name": "AddTopping", "attributes": [{"name": "amount", "type": "ToppingAmount"}]},
          {"name": "Purchase", "attributes": [{"name": "amount", "type": "Price"}]}]}]}"#;

    fn present(state: &str) -> String {
        let ir = Json::parse(IR).unwrap();
        let presenter = IrPresenter::from_ir(&ir);
        presenter
            .present("Pizzas::Order", Json::parse(state).unwrap())
            .to_json_string()
    }

    #[test]
    fn a_single_field_value_object_answers_as_its_sole_field() {
        assert_eq!(
            present(r#"{"name": {"value": "Margherita"}}"#),
            r#"{"name":"Margherita"}"#
        );
    }

    #[test]
    fn a_multi_field_value_object_unwraps_each_field() {
        assert_eq!(
            present(r#"{"pizza": {"price_cents": {"cents": 900}, "size": {"value": "large"}}}"#),
            r#"{"pizza":{"price_cents":900,"size":"large"}}"#
        );
    }

    #[test]
    fn a_list_maps_item_wise() {
        assert_eq!(
            present(r#"{"tags": [{"value": "a"}, {"value": "b"}]}"#),
            r#"{"tags":["a","b"]}"#
        );
    }

    #[test]
    fn a_name_declared_with_two_types_unwraps_by_the_keys_it_fits() {
        assert_eq!(present(r#"{"amount": {"value": 2}}"#), r#"{"amount":2}"#);
        assert_eq!(
            present(r#"{"amount": {"cents": 300}}"#),
            r#"{"amount":300}"#
        );
        assert_eq!(
            present(r#"{"amount": {"other": 1}}"#),
            r#"{"amount":{"other":1}}"#
        );
    }

    #[test]
    fn an_unknown_aggregate_and_an_unrelated_key_pass_through() {
        let ir = Json::parse(IR).unwrap();
        let presenter = IrPresenter::from_ir(&ir);
        let state = Json::parse(r#"{"name": {"value": "x"}}"#).unwrap();
        assert_eq!(
            presenter.present("Other::Thing", state).to_json_string(),
            r#"{"name":{"value":"x"}}"#
        );
        assert_eq!(present(r#"{"id": "1"}"#), r#"{"id":"1"}"#);
    }
}
