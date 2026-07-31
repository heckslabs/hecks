use crate::bluebook::expression::resolver::describe;
use crate::dispatcher::array;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::{Map, Value};
use std::sync::LazyLock;

// increment/decrement share one arithmetic primitive, differing only by
// sign — the same reduction Vocabulary::Comparison's algebra is for the six
// comparison operators. The language declares it in Vocabulary::MutationOp
// (language/bluebook.bluebook) ; Ruby's copy (CommandRules::MUTATION_OPS) is
// held equal to the language by spec/vocabulary_conformance_spec ; this
// file's copy is that table's JSON export, embedded at compile time.
// Regenerate with `bin/mutation_ops > rust/src/runtime/mutation_ops.json`
// any time MUTATION_OPS changes.
struct MutationOp {
    name: String,
    sign: Option<i64>,
}

static MUTATION_OPS_JSON: &str = include_str!("mutation_ops.json");

static MUTATION_OPS: LazyLock<Vec<MutationOp>> = LazyLock::new(|| {
    let parsed: Value =
        serde_json::from_str(MUTATION_OPS_JSON).expect("mutation_ops.json must parse as JSON");
    parsed
        .as_array()
        .expect("mutation_ops.json must hold an array")
        .iter()
        .map(|row| MutationOp {
            name: row["name"].as_str().expect("name").to_string(),
            sign: row["sign"].as_i64(),
        })
        .collect()
});

fn sign_of(operation: &str) -> i64 {
    MUTATION_OPS
        .iter()
        .find(|op| op.name == operation)
        .and_then(|op| op.sign)
        .unwrap_or(-1)
}

pub fn defaults_for(aggregate: &Map<String, Value>) -> Result<State, String> {
    let mut state = Map::new();

    for attribute in array(aggregate, "attributes") {
        let name = attribute
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let is_list = attribute
            .get("list")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let value = if is_list {
            Value::Array(Vec::new())
        } else {
            default_value(aggregate, &attribute)?
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
    Ok(state)
}

fn default_value(aggregate: &Map<String, Value>, attribute: &Value) -> Result<Value, String> {
    if let Some(default) = attribute.get("default").filter(|default| !default.is_null()) {
        return coerce_attribute(aggregate, attribute.as_object().unwrap_or(&Map::new()), default);
    }

    let Some(type_name) = attribute.get("type").and_then(Value::as_str) else {
        return Ok(Value::Null);
    };
    let Some(value_object) = value_object_named(aggregate, type_name) else {
        return Ok(Value::Null);
    };
    if !array(&value_object, "attributes").iter().all(|field| {
        field.get("default").is_some_and(|default| !default.is_null())
    }) {
        return Ok(Value::Null);
    }

    coerce_attribute(aggregate, attribute.as_object().unwrap_or(&Map::new()), &Value::Object(Map::new()))
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

/// A command takes the arguments it declares, and no others.
///
/// Anything else used to ride along in the payload untouched — the loop below
/// walks the DECLARED attributes, so a name the command never had was simply
/// never looked at. A misspelled argument was accepted in silence and did
/// nothing.
///
/// The keys that are legitimately not attributes ADDRESS the aggregate rather
/// than describe it: `id`, whatever the aggregate is identified by, the
/// reference key of the root a command reaches through, and the correlation key
/// a process manager threads through every leg it dispatches.
/// Called for AGGREGATE commands only, mirroring Ruby: the entity interpreter
/// has no such gate, and adding one here would split the runtimes.
pub fn refuse_unknown_arguments(
    aggregate: &Map<String, Value>,
    command: &Map<String, Value>,
    args: &State,
    correlation: &[String],
) -> Result<(), String> {
    let mut known: Vec<String> = array(command, "attributes")
        .iter()
        .filter_map(|attribute| attribute.get("name").and_then(Value::as_str))
        .map(str::to_string)
        .collect();
    let declared = known.join(", ");

    known.push("id".to_string());
    if let Some(identity) = aggregate.get("identified_by").and_then(Value::as_str) {
        // The HEAD, not the path. `identified_by { symbol.value }` means a caller
        // passes `symbol:` — admitting "symbol.value" would refuse it as undeclared.
        known.push(identity.split(char::from(46)).next().unwrap_or(identity).to_string());
    }
    if let Some(target) = command.get("references").and_then(Value::as_str) {
        known.push(crate::naming::reference_key(target));
    }
    known.extend(correlation.iter().cloned());

    // SORTED. Payload order is whatever the caller happened to write, and the two
    // runtimes iterate a map differently — an unsorted list makes the same refusal
    // read differently in Ruby and Rust, and parity says so.
    let mut unknown: Vec<&str> = args
        .keys()
        .map(String::as_str)
        .filter(|key| !known.iter().any(|allowed| allowed == key))
        .collect();
    unknown.sort_unstable();
    if unknown.is_empty() {
        return Ok(());
    }

    let command_name = command.get("name").and_then(Value::as_str).unwrap_or("");
    Err(format!(
        "{} does not declare {} — it takes {}",
        command_name,
        unknown.join(", "),
        declared
    ))
}

pub fn normalize_command_args(
    aggregate: &Map<String, Value>,
    command: &Map<String, Value>,
    args: &State,
) -> Result<State, String> {
    let mut normalized = args.clone();
    for attribute in array(command, "attributes") {
        let Some(name) = attribute.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(value) = normalized.get(name).cloned() else {
            continue;
        };
        let attribute = attribute.as_object().cloned().unwrap_or_default();
        normalized.insert(name.to_string(), coerce_attribute(aggregate, &attribute, &value)?);
    }
    Ok(normalized)
}

fn coerce(aggregate: &Map<String, Value>, name: &str, value: &Value) -> Result<Value, String> {
    let attribute = array(aggregate, "attributes")
        .into_iter()
        .find(|attribute| attribute.get("name").and_then(Value::as_str) == Some(name))
        .and_then(|attribute| attribute.as_object().cloned());
    let Some(attribute) = attribute else {
        return Ok(value.clone());
    };

    coerce_attribute(aggregate, &attribute, value)
}

pub fn coerce_attribute(
    aggregate: &Map<String, Value>,
    attribute: &Map<String, Value>,
    value: &Value,
) -> Result<Value, String> {
    if attribute
        .get("list")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return Ok(value.clone());
    }
    let Some(type_name) = attribute.get("type").and_then(Value::as_str) else {
        return Ok(value.clone());
    };
    let Some(value_object) = value_object_named(aggregate, type_name) else {
        return Ok(value.clone());
    };
    if value.is_null() {
        return Ok(value.clone());
    }
    if let Some(object) = value.as_object() {
        let mut completed = object.clone();
        for field in array(&value_object, "attributes") {
            let Some(name) = field.get("name").and_then(Value::as_str) else {
                continue;
            };
            if !completed.contains_key(name) {
                if let Some(default) = field.get("default").filter(|default| !default.is_null()) {
                    completed.insert(name.to_string(), default.clone());
                }
            }
        }
        admit_member(&value_object, &completed)?;
        check_numeric_fields(&value_object, &completed)?;
        enforce_invariants(&value_object, &completed)?;
        return Ok(Value::Object(completed));
    }

    let vo_name = value_object
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("");
    let name = attribute
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Err(format!(
        "{} is a {} — pass its fields as an object, not {}",
        name,
        vo_name,
        value
    ))
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

// No `aggregate` parameter : it was here only so the imitation branch above could
// look up the target's declared type and reproduce Ruby's leaked-symbol sentence.
// Arithmetic itself never needed the schema — it needs a current total and an
// amount — and dropping it is the honest measure of what that branch cost.
pub fn arithmetic(
    state: &State,
    target: &str,
    operation: &str,
    mutation: &Value,
    args: &State,
) -> Result<Value, String> {
    // An ABSENT argument used to be IMITATED here rather than fixed. Ruby's
    // resolve_source fell through to the Symbol itself when the argument was
    // missing, so `increment: :amount` with no amount reported "amount is a Money
    // — pass its fields as an object, not :amount" : a message about a mistake the
    // caller had not made. This function grew a `missing_argument` branch whose
    // whole job was to reproduce that sentence, and a `:{name}` rendering to match
    // the leaked symbol. Rust was taught to imitate an accident — so the two
    // runtimes agreed, and parity stayed green, over a bug they now shared. No
    // spec ever pinned it ; the two that pin "pass its fields as an object" both
    // pass a scalar on purpose, which is the real mistake and still refused.
    //
    // Ruby resolves an absent argument to nil now, so this reads it as nil too,
    // and both refuse it as what it actually is : not an Integer.
    let amount = resolve_source(mutation, args);
    let amount_int = integer_field(&amount, state.get(target));
    let Some(amount_int) = amount_int else {
        if amount.is_object() && state.get(target).is_some_and(Value::is_object) {
            return Err(format!(
                "{operation} of {target} needs a value object with one shared Integer field"
            ));
        }
        // describe(), not to_string() : Ruby words this with Rendering.describe and
        // the two have to read identically. They differ on exactly one value — nil,
        // which JSON spells "null" — and nil is precisely the value an absent
        // argument now arrives as, so raw to_string() here would have replaced one
        // split with another.
        return Err(format!(
            "{operation} of {target} needs an Integer, got {}",
            describe(&amount)
        ));
    };

    let current = state.get(target).cloned().unwrap_or(Value::Null);
    // `current ||= 0` — an unset total starts at zero, exactly as Ruby reads it.
    // This is the ONLY place a nil may stand in for a number : the AMOUNT above
    // has no such reading, and conflating the two is what made an absent argument
    // silently increment by zero here while Ruby refused it.
    let current_int = if current.is_null() {
        Some(0)
    } else {
        integer_field(&current, Some(&amount))
    };
    let Some(current_int) = current_int else {
        return Err(format!(
            "{operation} of {target} needs an Integer {target}, got {}",
            describe(&current)
        ));
    };

    let sign = sign_of(operation);
    if let (Some(current_fields), Some(amount_fields)) = (current.as_object(), amount.as_object()) {
        let field = current_fields.iter().find_map(|(name, value)| {
            value.as_i64().and_then(|_| amount_fields.get(name)?.as_i64().map(|_| name.clone()))
        }).expect("integer_field established a shared field");
        let mut updated = current_fields.clone();
        updated.insert(field, Value::from(current_int + sign * amount_int));
        return Ok(Value::Object(updated));
    }
    Ok(Value::from(current_int + sign * amount_int))
}

fn integer_field(value: &Value, counterpart: Option<&Value>) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_i64(),
        Value::Object(fields) => counterpart.and_then(Value::as_object).and_then(|other| {
            fields.iter().find_map(|(name, value)| {
                value.as_i64().filter(|_| other.get(name).and_then(Value::as_i64).is_some())
            })
        }),
        _ => None,
    }
}

pub fn resolve_source(mutation: &Value, args: &State) -> Value {
    let source = match mutation.get("source") {
        Some(source) => source,
        None => return Value::Null,
    };

    match source.get("kind").and_then(Value::as_str) {
        Some("argument") => {
            let name = source
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
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
            let value = if token.starts_with("{") && token.ends_with("}") {
                ruby_literal(token)
            } else if token.len() >= 2 && token.starts_with('"') && token.ends_with('"') {
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
        // The HEAD, not the path. A piece is GIVEN its identity here, and
        // what is filled in is the attribute — the path only says which
        // field inside it stands as the id.
        if let Some(key) = entity
            .get("identified_by")
            .and_then(Value::as_str)
            .map(|identity| identity.split('.').next().unwrap_or(identity).to_string())
        {
            let key = key.as_str();
            if !fields.contains_key(key) {
                let generated = Value::from(current_len as i64 + 1);
                let entity_attributes = array(&entity, "attributes");
                let identity_attribute = entity_attributes
                    .iter()
                    .find(|attribute| attribute.get("name").and_then(Value::as_str) == Some(key))
                    .and_then(Value::as_object);
                let value = identity_attribute
                    .and_then(|attribute| attribute.get("type").and_then(Value::as_str))
                    .and_then(|type_name| value_object_named(aggregate, type_name))
                    .and_then(|value_object| {
                        let value_attributes = array(&value_object, "attributes");
                        let field = value_attributes
                            .first()?
                            .get("name")?
                            .as_str()?;
                        Some(Value::Object(Map::from_iter([(field.to_string(), generated.clone())])))
                    })
                    .unwrap_or(generated);
                fields.insert(key.to_string(), value);
            }
        }
        if let Some(lifecycle) = entity.get("lifecycle").and_then(Value::as_object) {
            if let (Some(field), Some(default)) = (
                lifecycle.get("field").and_then(Value::as_str),
                lifecycle.get("default"),
            ) {
                fields
                    .entry(field.to_string())
                    .or_insert_with(|| default.clone());
            }
        }

        for attribute in array(&entity, "attributes") {
            let Some(name) = attribute.get("name").and_then(Value::as_str) else {
                continue;
            };
            let Some(value) = fields.get(name).cloned() else {
                continue;
            };
            let attribute = attribute.as_object().cloned().unwrap_or_default();
            fields.insert(
                name.to_string(),
                coerce_attribute(aggregate, &attribute, &value)?,
            );
        }
    }

    if let Some(value_object) = value_object_for(aggregate, target) {
        flatten_scalar_fields(aggregate, &value_object, &mut fields);
        admit_member(&value_object, &fields)?;
        enforce_invariants(&value_object, &fields)?;
    }

    Ok(Value::Object(fields))
}

/// Mirrors Ruby's `Value.check_numeric_fields` (`lib/hecksagain/runtime/value.rb`).
///
/// A field declared Integer or Float must ARRIVE as one. Without this a string
/// sails into a numeric field and the failure surfaces later, inside a
/// predicate, as `positive? expects a number, got "three"` — which is not the
/// domain refusing, it is the runtime breaking, and the run contract recorded
/// it beside genuine refusals.
///
/// Checked BEFORE invariants, because an invariant reading a mistyped field is
/// exactly what used to explode. The message is byte-identical to Ruby's.
fn check_numeric_fields(
    value_object: &Map<String, Value>,
    fields: &Map<String, Value>,
) -> Result<(), String> {
    let vo_name = value_object
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    for attribute in array(value_object, "attributes") {
        let Some(name) = attribute.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(type_name) = attribute.get("type").and_then(Value::as_str) else {
            continue;
        };
        let numeric = match type_name {
            "Integer" => true,
            "Float" => true,
            _ => continue,
        };
        let Some(given) = fields.get(name) else { continue };
        if given.is_null() {
            continue;
        }
        let ok = if type_name == "Integer" {
            given.is_i64() || given.is_u64()
        } else {
            given.is_number()
        };
        if numeric && !ok {
            return Err(format!(
                "{vo_name}.{name} expects {type_name}, got {}",
                render_scalar(given)
            ));
        }
    }
    Ok(())
}

/// Ruby's `#inspect` for the values a bluebook field can hold — a string gets
/// quotes, a number does not. Parity compares these messages byte-for-byte.
fn render_scalar(value: &Value) -> String {
    match value {
        Value::String(text) => format!("{text:?}"),
        other => other.to_string(),
    }
}

/// Mirrors Ruby's `Value.scalar` (`lib/hecksagain/runtime/value.rb:87`) at the
/// append boundary.
///
/// A command attribute is a value object, but the element it is appended INTO
/// may declare that same field as a scalar — `then_set :toppings, append: {
/// amount: :amount }` where the argument is a `ToppingAmount` and
/// `Topping.amount` is an `Integer`. Ruby flattens the single-field value
/// object to the scalar it stands for ; without this Rust stored the whole
/// `{"value":3}` and every predicate reading it failed with
/// `positive? expects a number, got {"value":3}`.
///
/// Only fields the element declares as SCALAR are flattened — a legitimately
/// nested value object is left intact. A multi-field value object standing in
/// for a scalar is left untouched here rather than guessed at; Ruby raises
/// `TypeMismatch` for that case and no corpus step reaches it yet.
fn flatten_scalar_fields(
    aggregate: &Map<String, Value>,
    value_object: &Map<String, Value>,
    fields: &mut Map<String, Value>,
) {
    for attribute in array(value_object, "attributes") {
        let Some(name) = attribute.get("name").and_then(Value::as_str) else {
            continue;
        };
        let declared_scalar = match attribute.get("type").and_then(Value::as_str) {
            Some(type_name) => value_object_named(aggregate, type_name).is_none(),
            None => true,
        };
        if !declared_scalar {
            continue;
        }
        let Some(Value::Object(supplied)) = fields.get(name) else {
            continue;
        };
        if supplied.len() != 1 {
            continue;
        }
        let Some(scalar) = supplied.values().next().cloned() else {
            continue;
        };
        fields.insert(name.to_string(), scalar);
    }
}

fn ruby_literal(token: &str) -> Value {
    let mut fields = Map::new();
    for pair in token[1..token.len() - 1].split(',') {
        let Some((key, value)) = pair.split_once("=>") else { continue };
        fields.insert(
            key.trim().trim_start_matches(':').to_string(),
            Value::String(value.trim().trim_matches('"').to_string()),
        );
    }
    Value::Object(fields)
}

fn admit_member(
    value_object: &Map<String, Value>,
    fields: &Map<String, Value>,
) -> Result<(), String> {
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
                match (
                    pair.first().and_then(Value::as_str),
                    pair.get(1).and_then(Value::as_str),
                ) {
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
    let name = value_object
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let rendered: Vec<String> = admitted.iter().map(|value| format!("{value:?}")).collect();
    let got = match &offered {
        Value::String(text) => format!("{text:?}"),
        Value::Null => "nil".to_string(),
        other => other.to_string(),
    };
    Err(format!(
        "{} admits {} — got {}",
        name,
        rendered.join(", "),
        got
    ))
}

fn enforce_invariants(
    value_object: &Map<String, Value>,
    fields: &Map<String, Value>,
) -> Result<(), String> {
    let empty = Map::new();
    for invariant in array(value_object, "invariants") {
        let canonical = invariant
            .get("canonical")
            .and_then(Value::as_str)
            .unwrap_or("");
        if evaluate_given(canonical, fields, &empty)? {
            continue;
        }
        let description = invariant
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let name = value_object
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
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

fn value_object_named(aggregate: &Map<String, Value>, name: &str) -> Option<Map<String, Value>> {
    array(aggregate, "value_objects")
        .iter()
        .find(|v| v.get("name").and_then(Value::as_str) == Some(name))?
        .as_object()
        .cloned()
}

fn value_object_for(aggregate: &Map<String, Value>, target: &str) -> Option<Map<String, Value>> {
    let element_type = array(aggregate, "attributes")
        .into_iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some(target))?
        .get("type")
        .and_then(Value::as_str)?
        .to_string();

    value_object_named(aggregate, &element_type)
}

#[cfg(test)]
mod sign_tests {
    use super::*;

    #[test]
    fn increment_and_decrement_read_their_sign_from_the_declared_table() {
        assert_eq!(sign_of("increment"), 1);
        assert_eq!(sign_of("decrement"), -1);
    }

    #[test]
    fn set_and_append_never_reach_sign_of_but_default_safely_if_they_did() {
        assert_eq!(sign_of("set"), -1);
        assert_eq!(sign_of("append"), -1);
    }

    #[test]
    fn the_table_holds_exactly_the_four_declared_ops() {
        let mut names: Vec<&str> = MUTATION_OPS.iter().map(|op| op.name.as_str()).collect();
        names.sort();
        assert_eq!(names, vec!["append", "decrement", "increment", "set"]);
    }
}
