
use crate::dispatcher::array;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::{Map, Value};

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

    if let Some(lifecycle) = aggregate.get("lifecycle").and_then(Value::as_object) {
        if let (Some(field), Some(default)) = (
            lifecycle.get("field").and_then(Value::as_str),
            lifecycle.get("default"),
        ) {
            state.insert(field.to_string(), default.clone());
        }
    }
    state
}

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

fn coerce(aggregate: &Map<String, Value>, name: &str, value: &Value) -> Result<Value, String> {
    if is_list_attribute(aggregate, name) {
        return Ok(value.clone());
    }
    let Some(value_object) = value_object_for(aggregate, name) else {
        return Ok(value.clone());
    };
    if value.is_null() {
        return Ok(value.clone());
    }
    if let Some(object) = value.as_object() {
        admit_member(&value_object, object)?;
        enforce_invariants(&value_object, object)?;
        return Ok(value.clone());
    }

    let fields: Vec<String> = array(&value_object, "attributes")
        .iter()
        .filter_map(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
        .collect();

    if fields.len() == 1 {
        let mut only = Map::new();
        only.insert(fields[0].clone(), value.clone());
        admit_member(&value_object, &only)?;
        enforce_invariants(&value_object, &only)?;
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
            let mut items = state
                .get(&target)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let element = build_element(aggregate, &target, mutation, args, items.len())?;
            items.push(element);
            state.insert(target, Value::Array(items));
        }
        "increment" | "decrement" => {
            let updated = arithmetic(state, &target, operation, mutation, args)?;
            state.insert(target, updated);
        }
        _ => {
            let value = resolve_source(mutation, args);
            let coerced = coerce(aggregate, &target, &value)?;
            state.insert(target, coerced);
        }
    }
    Ok(())
}

pub fn arithmetic(
    state: &State,
    target: &str,
    operation: &str,
    mutation: &Value,
    args: &State,
) -> Result<Value, String> {
    let source = mutation.get("source");
    let missing_argument = source
        .and_then(|s| s.get("kind"))
        .and_then(Value::as_str)
        == Some("argument")
        && source
            .and_then(|s| s.get("name"))
            .and_then(Value::as_str)
            .is_some_and(|name| !args.contains_key(name));

    let amount = resolve_source(mutation, args);
    let amount_int = match &amount {
        Value::Number(n) if !missing_argument => n.as_i64(),
        _ => None,
    };
    let Some(amount_int) = amount_int else {
        let shown = if missing_argument {
            let name = source
                .and_then(|s| s.get("name"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            format!(":{name}")
        } else {
            amount.to_string()
        };
        return Err(format!("{operation} of {target} needs an Integer, got {shown}"));
    };

    let current = state.get(target).cloned().unwrap_or(Value::Null);
    let current_int = match &current {
        Value::Null => Some(0),
        Value::Number(n) => n.as_i64(),
        _ => None,
    };
    let Some(current_int) = current_int else {
        return Err(format!(
            "{operation} of {target} needs an Integer {target}, got {current}"
        ));
    };

    let sign = if operation == "increment" { 1 } else { -1 };
    Ok(Value::from(current_int + sign * amount_int))
}

pub fn resolve_source(mutation: &Value, args: &State) -> Value {
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

fn build_element(
    aggregate: &Map<String, Value>,
    target: &str,
    mutation: &Value,
    args: &State,
    current_len: usize,
) -> Result<Value, String> {
    let mut fields = Map::new();

    if let Some(mapping) = mutation.get("fields").and_then(Value::as_object) {
        for (field, token) in mapping {
            let token = token.as_str().unwrap_or_default();
            let value = if token.len() >= 2 && token.starts_with('"') && token.ends_with('"') {
                Value::String(token[1..token.len() - 1].to_string())
            } else if let Ok(number) = token.parse::<i64>() {
                Value::from(number)
            } else {
                args.get(token).cloned().unwrap_or(Value::Null)
            };
            fields.insert(field.clone(), value);
        }
    }

    if let Some(entity) = entity_for(aggregate, target) {
        if let Some(key) = entity.get("identified_by").and_then(Value::as_str) {
            fields
                .entry(key.to_string())
                .or_insert_with(|| Value::from(current_len as i64 + 1));
        }
        if let Some(lifecycle) = entity.get("lifecycle").and_then(Value::as_object) {
            if let (Some(field), Some(default)) = (
                lifecycle.get("field").and_then(Value::as_str),
                lifecycle.get("default"),
            ) {
                fields.entry(field.to_string()).or_insert_with(|| default.clone());
            }
        }
    }

    if let Some(value_object) = value_object_for(aggregate, target) {
        admit_member(&value_object, &fields)?;
        enforce_invariants(&value_object, &fields)?;
    }

    Ok(Value::Object(fields))
}

fn admit_member(value_object: &Map<String, Value>, fields: &Map<String, Value>) -> Result<(), String> {
    let members = array(value_object, "members");
    if members.is_empty() {
        return Ok(());
    }
    let discriminant = array(value_object, "attributes")
        .first()
        .and_then(|a| a.get("name").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string();
    let admitted: Vec<String> = members
        .iter()
        .filter_map(Value::as_array)
        .filter_map(|pairs| {
            pairs.iter().filter_map(Value::as_array).find_map(|pair| {
                match (pair.first().and_then(Value::as_str), pair.get(1).and_then(Value::as_str)) {
                    (Some(field), Some(value)) if field == discriminant => Some(value.to_string()),
                    _ => None,
                }
            })
        })
        .collect();
    let offered = fields.get(&discriminant).cloned().unwrap_or(Value::Null);
    let offered_text = match &offered {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    if admitted.iter().any(|value| *value == offered_text) {
        return Ok(());
    }
    let name = value_object.get("name").and_then(Value::as_str).unwrap_or_default();
    let rendered: Vec<String> = admitted.iter().map(|value| format!("{value:?}")).collect();
    let got = match &offered {
        Value::String(text) => format!("{text:?}"),
        Value::Null => "nil".to_string(),
        other => other.to_string(),
    };
    Err(format!("{} admits {} — got {}", name, rendered.join(", "), got))
}

fn enforce_invariants(value_object: &Map<String, Value>, fields: &Map<String, Value>) -> Result<(), String> {
    let empty = Map::new();
    for invariant in array(value_object, "invariants") {
        let canonical = invariant.get("canonical").and_then(Value::as_str).unwrap_or("");
        if evaluate_given(canonical, fields, &empty)? {
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
    Ok(())
}

pub fn entity_for(aggregate: &Map<String, Value>, target: &str) -> Option<Map<String, Value>> {
    let element_type = array(aggregate, "attributes")
        .iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some(target))?
        .get("type")
        .and_then(Value::as_str)?
        .to_string();

    array(aggregate, "entities")
        .iter()
        .find(|e| e.get("name").and_then(Value::as_str) == Some(element_type.as_str()))
        .and_then(|e| e.as_object().cloned())
}

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
