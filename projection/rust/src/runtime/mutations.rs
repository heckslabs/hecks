//! interp_mutations - the then_set executor and the value-object gate.
//!
//! Ported from rust/src/runtime/interp_mutations.rs in the Hecks runtime. Two
//! operations only:
//!
//!   set     replace an attribute, from a command argument or a literal
//!   append  build a value object from the payload and push it onto a list
//!
//! The argument-vs-literal distinction rides in the IR rather than being
//! guessed from the text: Ruby knows it by Symbol-vs-String, and the exporter
//! writes it explicitly so this side never has to guess.

use crate::dispatcher::array;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::{Map, Value};

/// Starting state straight from the IR: empty list for a list attribute, the
/// declared default otherwise. The runtime never invents a shape the bluebook
/// did not declare.
pub fn defaults_for(aggregate: &Map<String, Value>) -> State {
    let mut state = Map::new();

    for attribute in array(aggregate, "attributes") {
        let name = attribute
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let is_list = attribute.get("list").and_then(Value::as_bool).unwrap_or(false);

        let value = if is_list {
            Value::Array(Vec::new())
        } else {
            attribute.get("default").cloned().unwrap_or(Value::Null)
        };
        state.insert(name, value);
    }
    state
}

/// On creation, a command attribute sharing a name with an aggregate attribute
/// lands on it. No then_set needed for the obvious case.
pub fn assign_creation_attributes(
    state: &mut State,
    aggregate: &Map<String, Value>,
    command: &Map<String, Value>,
    args: &State,
) -> Result<(), String> {
    let declared: Vec<String> = array(aggregate, "attributes")
        .iter()
        .filter_map(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
        .collect();

    for attribute in array(command, "attributes") {
        let name = match attribute.get("name").and_then(Value::as_str) {
            Some(name) => name.to_string(),
            None => continue,
        };
        if !declared.contains(&name) {
            continue;
        }
        if let Some(value) = args.get(&name) {
            let coerced = coerce(aggregate, &name, value)?;
            state.insert(name, coerced);
        }
    }
    Ok(())
}

/// A VALUE-OBJECT-TYPED FIELD IS CONSTRUCTED, NOT STORED RAW.
///
/// A scalar attribute declared as a value object used to be assigned whatever
/// arrived: `amount: 2500` on an attribute typed Money sat there as a number,
/// and `amount.cents` — a dotted read into what the domain says is a Money —
/// walked into a non-object and answered Null. Ruby did exactly the same, so
/// parity was green over a value object that never existed.
///
/// A SINGLE-ATTRIBUTE value object accepts a bare scalar, because `kind:
/// "current"` is unambiguous. Anything richer must arrive as its fields —
/// guessing which of several a scalar meant is how a currency ends up in a
/// cents column.
///
/// The refusal wording is Ruby's, to the character. A message that differs
/// between runtimes is a difference the harness has to explain away.
fn coerce(aggregate: &Map<String, Value>, name: &str, value: &Value) -> Result<Value, String> {
    if is_list_attribute(aggregate, name) {
        return Ok(value.clone());
    }
    let Some(value_object) = value_object_for(aggregate, name) else {
        return Ok(value.clone());
    };
    if value.is_null() || value.is_object() {
        return Ok(value.clone());
    }

    let fields: Vec<String> = array(&value_object, "attributes")
        .iter()
        .filter_map(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
        .collect();

    if fields.len() == 1 {
        let mut only = Map::new();
        only.insert(fields[0].clone(), value.clone());
        return Ok(Value::Object(only));
    }

    let vo_name = value_object.get("name").and_then(Value::as_str).unwrap_or("");
    Err(format!(
        "{} is a {}, which has {} — pass those fields, not {}. A scalar can only \
         stand in for a value object with exactly one field.",
        name,
        vo_name,
        fields.join(", "),
        value
    ))
}

/// A list attribute is built element by element on append, never coerced whole.
fn is_list_attribute(aggregate: &Map<String, Value>, name: &str) -> bool {
    array(aggregate, "attributes")
        .iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some(name))
        .and_then(|a| a.get("list"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

pub fn apply_mutation(
    state: &mut State,
    aggregate: &Map<String, Value>,
    mutation: &Value,
    args: &State,
) -> Result<(), String> {
    let target = mutation
        .get("target")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let operation = mutation.get("op").and_then(Value::as_str).unwrap_or("set");

    match operation {
        "append" => {
            let element = build_element(aggregate, &target, mutation, args)?;
            let mut items = state
                .get(&target)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            items.push(element);
            state.insert(target, Value::Array(items));
        }
        _ => {
            // Coerced here too, not only on creation : `then_set :kind, to: :kind`
            // assigns a value-object-typed field just as directly as a creation
            // attribute does, and a Money that is a value object on one path and
            // a bare scalar on the other is two different records.
            let value = resolve_source(mutation, args);
            let coerced = coerce(aggregate, &target, &value)?;
            state.insert(target, coerced);
        }
    }
    Ok(())
}

/// A source is either a named command argument or a literal, and the IR says
/// which. Guessing from the text is exactly the bug this avoids.
fn resolve_source(mutation: &Value, args: &State) -> Value {
    let source = match mutation.get("source") {
        Some(source) => source,
        None => return Value::Null,
    };

    match source.get("kind").and_then(Value::as_str) {
        Some("argument") => {
            let name = source.get("name").and_then(Value::as_str).unwrap_or_default();
            args.get(name).cloned().unwrap_or(Value::Null)
        }
        _ => source.get("value").cloned().unwrap_or(Value::Null),
    }
}

/// Build the value object being appended, and enforce its invariants BEFORE it
/// reaches the aggregate. An aggregate never holds a value that broke its own
/// rule.
fn build_element(
    aggregate: &Map<String, Value>,
    target: &str,
    mutation: &Value,
    args: &State,
) -> Result<Value, String> {
    let mut fields = Map::new();

    if let Some(mapping) = mutation.get("fields").and_then(Value::as_object) {
        for (field, argument) in mapping {
            let name = argument.as_str().unwrap_or_default();
            fields.insert(field.clone(), args.get(name).cloned().unwrap_or(Value::Null));
        }
    }

    if let Some(value_object) = value_object_for(aggregate, target) {
        let empty = Map::new();
        for invariant in array(&value_object, "invariants") {
            let canonical = invariant.get("canonical").and_then(Value::as_str).unwrap_or("");
            if evaluate_given(canonical, &fields, &empty)? {
                continue;
            }
            let description = invariant
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let name = value_object.get("name").and_then(Value::as_str).unwrap_or_default();
            return Err(format!(
                "{} invariant violated — {} (given {})",
                name,
                description,
                Value::Object(fields.clone())
            ));
        }
    }

    Ok(Value::Object(fields))
}

/// The value object a list attribute holds, found through the attribute's
/// declared element type.
fn value_object_for(aggregate: &Map<String, Value>, target: &str) -> Option<Map<String, Value>> {
    let element_type = array(aggregate, "attributes")
        .iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some(target))?
        .get("type")
        .and_then(Value::as_str)?
        .to_string();

    array(aggregate, "value_objects")
        .iter()
        .find(|v| v.get("name").and_then(Value::as_str) == Some(element_type.as_str()))?
        .as_object()
        .cloned()
}
