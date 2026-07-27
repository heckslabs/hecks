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

    // The lifecycle's field is born at the lifecycle's default —
    // `lifecycle :status, default: "open"` DECLARES an attribute as surely as
    // `attribute` does. Until this block it declared nothing, every status in
    // the corpus was absent from state, and Freeze froze nothing in either
    // runtime. Mirrors Ruby's Instance.defaults.
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
    if value.is_null() {
        return Ok(value.clone());
    }
    // An OBJECT payload used to pass through here untouched — Ruby built and
    // judged it, Rust stored it raw, and a value that broke its own rule would
    // have split the runtimes the first time anyone sent one. Every
    // construction now walks the same door : members first, invariants second.
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

/// Integer cents or nothing — the wording is Ruby's `arithmetic`, to the
/// character. Hecks's runtime falls back to ±1 when an amount will not read
/// as a number ; a balance moving by one cent because the caller sent "lots"
/// is exactly the silent wrongness this refuses to inherit.
///
/// A MISSING argument renders the way Ruby sees it : resolve_source there
/// returns the Symbol itself, so the refusal says `got :amount` — mirrored
/// here from the source descriptor, because a runtime that words the same
/// refusal differently is a diff the harness has to explain away.
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

/// A source is either a named command argument or a literal, and the IR says
/// which. Guessing from the text is exactly the bug this avoids.
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

/// Build the value object being appended, and enforce its invariants BEFORE it
/// reaches the aggregate. An aggregate never holds a value that broke its own
/// rule.
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
            // An appended field is either an ARGUMENT to read or a LITERAL to
            // write, and the IR spells which : arguments bare, string literals
            // with their quotes, numbers as digits. This used to read EVERY
            // field as an argument lookup, so `direction: "credit"` looked up
            // an argument called `"credit"`, found nothing, and every ledger
            // entry in the corpus carried `direction: null` — in BOTH runtimes,
            // which is why parity never said a word.
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

    // An ENTITY element is born WITH its identity and its lifecycle state —
    // the projection of Ruby's `entity_element`. Identity defaults to its
    // 1-based position (append order IS the order it was posted) unless the
    // append names it ; the lifecycle field starts at the declared default.
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

/// `one_of` declares the CLOSED SET of values this object may take. The
/// judgment falls on the DISCRIMINANT — the first declared attribute, the
/// value a caller actually offers. Member rows ride the canonical IR as
/// strings, so both runtimes compare and render the seam's spelling.
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

/// A violated invariant refuses BEFORE the value reaches the aggregate — an
/// aggregate never holds a value that broke its own rule.
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

/// The ENTITY a list attribute holds, when its element type names one.
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
