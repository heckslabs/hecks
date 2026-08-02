use crate::bluebook::expression::resolver::describe;
use crate::dispatcher::array;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::runtime::refusal_wording;
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
    // THE HEADS, not the paths — `identified_by { symbol.value }` means a caller
    // passes `symbol:`, and admitting "symbol.value" would refuse it as
    // undeclared. EVERY head, because a composite identity is addressed by all
    // its parts: admitting only the first refused `number:` on a stall the
    // caller had named correctly, and named the argument undeclared when the
    // bluebook declares it as half the identity.
    known.extend(crate::identity::heads(aggregate).into_iter().map(str::to_string));
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
    let unknown_joined = unknown.join(", ");
    Err(refusal_wording::render(
        "UnknownArgument",
        "unknown_args",
        &[("command", command_name), ("unknown", &unknown_joined), ("declared", &declared)],
    ))
}

/// And it takes ALL of them. The other half of the same sentence, missing until
/// fuzz went looking : a name the command never declared was refused, while a
/// name it DID declare could simply be left out.
///
/// Rust wrote `name: null` and carried on, because `assign_creation_attributes`
/// only ever assigned the arguments that were present. Ruby refused the same
/// payload, but by ACCIDENT — an unresolved `then_set` leaking its literal source
/// symbol into coercion — and with a message describing a mistake the caller did
/// not make. Neither runtime was refusing the real one, and the seam between the
/// two accidents is what showed up as a parity SPLIT.
///
/// No command attribute anywhere in the corpus carries a default — checked, all
/// eight chapters, zero — so there is no optional argument for this to step on.
pub fn refuse_absent_arguments(command: &Map<String, Value>, args: &State) -> Result<(), String> {
    let declared: Vec<String> = array(command, "attributes")
        .iter()
        .filter_map(|attribute| attribute.get("name").and_then(Value::as_str))
        .map(str::to_string)
        .collect();

    // SORTED, for the same reason the unknown list is : declaration order is stable
    // but the two runtimes reach it differently, and a refusal has to read
    // identically in both or parity says so.
    let required: Vec<String> = array(command, "attributes")
        .iter()
        .filter(|attribute| {
            !attribute
                .get("optional")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .filter_map(|attribute| attribute.get("name").and_then(Value::as_str))
        .map(str::to_string)
        .collect();

    let mut absent: Vec<&str> = required
        .iter()
        .map(String::as_str)
        .filter(|name| !args.contains_key(*name))
        .collect();
    absent.sort_unstable();
    if absent.is_empty() {
        return Ok(());
    }

    let command_name = command.get("name").and_then(Value::as_str).unwrap_or("");
    let absent_joined = absent.join(", ");
    let declared_joined = declared.join(", ");
    Err(refusal_wording::render(
        "AbsentArgument",
        "absent_args",
        &[("command", command_name), ("absent", &absent_joined), ("declared", &declared_joined)],
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
        admit_declared_set(attribute, value)?;
        return Ok(value.clone());
    };
    let Some(value_object) = value_object_named(aggregate, type_name) else {
        // A PLAIN FIELD STILL ADMITS WHAT IT SAYS IT ADMITS. Nothing to coerce
        // here — no value object names this type — but the set is named on the
        // attribute, not on the type, so the refusal belongs on this path too.
        admit_declared_set(attribute, value)?;
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
        check_admitted(&value_object, &completed)?;
        check_numeric_fields(&value_object, &completed)?;
        check_patterns(&value_object, &completed)?;
        enforce_invariants(&value_object, &completed)?;
        // AFTER coercion, not before: a scalar arrives wrapped in whatever
        // holder its type names, and checking the raw payload would be checking
        // the envelope.
        let coerced = Value::Object(completed);
        admit_declared_set(attribute, &coerced)?;
        return Ok(coerced);
    }

    let vo_name = value_object
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("");
    let name = attribute
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let offered = value.to_string();
    Err(refusal_wording::render(
        "TypeMismatch",
        "value_object_shape",
        &[("name", name), ("type", vo_name), ("offered", &offered)],
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
            return Err(refusal_wording::render(
                "TypeMismatch",
                "arithmetic_shared_field",
                &[("op", operation), ("target", target)],
            ));
        }
        // describe(), not to_string() : Ruby words this with Rendering.describe and
        // the two have to read identically. They differ on exactly one value — nil,
        // which JSON spells "null" — and nil is precisely the value an absent
        // argument now arrives as, so raw to_string() here would have replaced one
        // split with another.
        let offered = describe(&amount);
        return Err(refusal_wording::render(
            "TypeMismatch",
            "arithmetic_amount",
            &[("op", operation), ("target", target), ("offered", &offered)],
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
        let offered = describe(&current);
        return Err(refusal_wording::render(
            "TypeMismatch",
            "arithmetic_current",
            &[("op", operation), ("target", target), ("offered", &offered)],
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
        //
        // ONLY WHEN THERE IS ONE HEAD TO GIVE, and this is a RULE rather than
        // a gap. What is generated is a running number — "the next one in this
        // list" — which is an answer for a piece known by its position and no
        // answer at all for one known by two facts. Half of a composite is not
        // an identity, so the caller supplies every part or the append is
        // refused downstream by the invariants on the parts it left out.
        // Ruby says the same by reading `entity.identified_by`, which is the
        // single head and is nil the moment there are two. Taking the FIRST
        // head here was a real divergence: Rust filled one part in and Ruby
        // filled none.
        if let [key] = crate::identity::heads(&entity)[..] {
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
        check_admitted(&value_object, &fields)?;
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
            let offered = render_scalar(given);
            return Err(refusal_wording::render(
                "TypeMismatch",
                "numeric_field",
                &[("type", vo_name), ("field", name), ("expected", type_name), ("offered", &offered)],
            ));
        }
    }
    Ok(())
}

/// A field declared with a PATTERN must match it.
///
/// Beside check_numeric_fields and for the same reason : a value that does not
/// look like what it claims to be is the DOMAIN saying no, and it should say so
/// here rather than let the wrong shape travel on and surface as a broken
/// predicate later.
///
/// Which regexes may be written at all is pattern_subset's job — so by the time
/// a value arrives here the pattern is already one both runtimes read the same
/// way, and this is a plain match. The message is byte-identical to Ruby's.
fn check_patterns(
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
        let Some(pattern) = attribute.get("pattern").and_then(Value::as_str) else {
            continue;
        };
        let Some(given) = fields.get(name) else { continue };
        if given.is_null() {
            continue;
        }

        let satisfied = match given.as_str() {
            Some(text) => crate::pattern_subset::matches(pattern, text)?,
            None => false,
        };
        if !satisfied {
            let offered = render_scalar(given);
            return Err(refusal_wording::render(
                "TypeMismatch",
                "pattern_mismatch",
                &[("type", vo_name), ("field", name), ("pattern", pattern), ("offered", &offered)],
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

/// Where a resolved `admits` keeps its members on the runtime's own copy of the
/// IR. NEVER ON THE WIRE — `--dump` projects from the typed IR, not from here,
/// and the wire carries the NAME so each runtime resolves against what it itself
/// declares. This is a cache of that resolution, filled once at load.
const ADMITTED: &str = "admitted_members";

/// EVERY `admits` RESOLVED ONCE, when the runtime takes its IR.
///
/// Coercion happens deep inside `coerce_attribute`, which is handed ONE
/// aggregate and has no way back up to the chapter — and the set an attribute
/// admits belongs to a DIFFERENT aggregate, because that is the whole point of
/// naming it rather than restating it. Ruby walks up through `hecks_owner` ;
/// JSON has no parent pointers, so the walk happens once here instead of
/// threading a domain through seven signatures that do not otherwise want one.
pub fn resolve_admitted_sets(ir: Value) -> Value {
    let Value::Object(domains) = ir else {
        return ir;
    };
    Value::Object(
        domains
            .into_iter()
            .map(|(name, domain)| {
                let sets = admitted_sets_of(&domain);
                (name, annotate_admits(domain, &sets))
            })
            .collect(),
    )
}

/// Every closed set the chapter declares, keyed the way an `admits` names it.
fn admitted_sets_of(domain: &Value) -> Map<String, Value> {
    let mut sets = Map::new();
    let Some(aggregates) = domain.get("aggregates").and_then(Value::as_array) else {
        return sets;
    };
    for aggregate in aggregates {
        let Some(aggregate_name) = aggregate.get("name").and_then(Value::as_str) else {
            continue;
        };
        for value_object in aggregate
            .get("value_objects")
            .and_then(Value::as_array)
            .unwrap_or(&vec![])
        {
            let (Some(set_name), Some(set)) = (
                value_object.get("name").and_then(Value::as_str),
                value_object.as_object(),
            ) else {
                continue;
            };
            let members = admitted_values(set);
            if members.is_empty() {
                continue;
            }
            sets.insert(
                format!("{aggregate_name}::{set_name}"),
                Value::Array(members.into_iter().map(Value::String).collect()),
            );
        }
    }
    sets
}

/// Walked generically rather than construct by construct: an attribute is an
/// attribute wherever it is written — on a head, an argument, a piece, an ask,
/// a value object's own field — and a walk that names the places it visits is a
/// walk that misses the next place one is added.
fn annotate_admits(node: Value, sets: &Map<String, Value>) -> Value {
    match node {
        Value::Object(map) => {
            let mut out: Map<String, Value> = map
                .into_iter()
                .map(|(key, value)| (key, annotate_admits(value, sets)))
                .collect();
            if let Some(members) = out
                .get("admits")
                .and_then(Value::as_str)
                .and_then(|named| sets.get(named))
                .cloned()
            {
                out.insert(ADMITTED.to_string(), members);
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .map(|item| annotate_admits(item, sets))
                .collect(),
        ),
        other => other,
    }
}

/// Mirrors Ruby's `Value.admit_declared_set` (`lib/hecksagain/runtime/value.rb`).
///
/// `admit_member` below refuses a non-member when the value object BEING BUILT
/// is itself the closed set. This is the other direction: the value is ordinary
/// text and the set it must belong to was declared once, elsewhere, and named.
fn admit_declared_set(attribute: &Map<String, Value>, value: &Value) -> Result<(), String> {
    let Some(named) = attribute.get("admits").and_then(Value::as_str) else {
        return Ok(());
    };
    if value.is_null() {
        return Ok(());
    }
    let field = attribute
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let Some(admitted) = attribute.get(ADMITTED).and_then(Value::as_array) else {
        return Err(refusal_wording::render(
            "InvariantViolation",
            "undeclared_set",
            &[("name", field), ("admits", named)],
        ));
    };
    let offered = admitted_scalar(value);
    let offered_text = match &offered {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    if admitted
        .iter()
        .filter_map(Value::as_str)
        .any(|value| value == offered_text)
    {
        return Ok(());
    }
    let rendered: Vec<String> = admitted
        .iter()
        .filter_map(Value::as_str)
        .map(|value| format!("{value:?}"))
        .collect();
    let got = match &offered {
        Value::String(text) => format!("{text:?}"),
        Value::Null => "nil".to_string(),
        other => other.to_string(),
    };
    let rendered_joined = rendered.join(", ");
    Err(refusal_wording::render(
        "InvariantViolation",
        "admits_declared_set",
        &[("name", field), ("admits", named), ("admitted", &rendered_joined), ("offered", &got)],
    ))
}

/// An admitted value is a SCALAR however it arrived — bare on a plain field, or
/// wrapped in the one-field holder its type names.
fn admitted_scalar(value: &Value) -> Value {
    match value.as_object() {
        Some(fields) if fields.len() == 1 => fields.values().next().cloned().unwrap_or(Value::Null),
        _ => value.clone(),
    }
}

/// Mirrors Ruby's `Value.check_admitted`. A value object's own field may name a
/// set too — `Query::Filter.op` is a plain String field that admits
/// `Vocabulary::QueryComparator`, and no attribute passes through
/// `coerce_attribute` on its way in.
fn check_admitted(
    value_object: &Map<String, Value>,
    fields: &Map<String, Value>,
) -> Result<(), String> {
    for attribute in array(value_object, "attributes") {
        let Some(attribute) = attribute.as_object() else {
            continue;
        };
        if attribute.get("admits").and_then(Value::as_str).is_none() {
            continue;
        }
        let Some(name) = attribute.get("name").and_then(Value::as_str) else {
            continue;
        };
        admit_declared_set(
            attribute,
            &fields.get(name).cloned().unwrap_or(Value::Null),
        )?;
    }
    Ok(())
}

/// The values a closed set admits, read through its discriminant — the first
/// field, which is what a member row is keyed by.
fn admitted_values(value_object: &Map<String, Value>) -> Vec<String> {
    let members = array(value_object, "members");
    if members.is_empty() {
        return vec![];
    }
    let discriminant = array(value_object, "attributes")
        .first()
        .and_then(|a| a.get("name").and_then(Value::as_str))
        .unwrap_or_default()
        .to_string();
    members
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
        .collect()
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
    let rendered_joined = rendered.join(", ");
    Err(refusal_wording::render(
        "InvariantViolation",
        "closed_set_member",
        &[("type", name), ("admitted", &rendered_joined), ("offered", &got)],
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

    /// A closed set declared in a SIBLING aggregate, named rather than restated.
    fn kitchen() -> Value {
        serde_json::json!({ "Kitchen": { "aggregates": [
            { "name": "Vocabulary", "attributes": [], "value_objects": [
                { "name": "Doneness",
                  "attributes": [{ "name": "name", "type": "String", "list": false,
                                   "optional": false, "pattern": null, "admits": null }],
                  "members": [[["name", "rare"]], [["name", "medium"]], [["name", "well"]]] }
            ] },
            { "name": "Steak", "value_objects": [], "attributes": [
                { "name": "doneness", "type": "String", "list": false, "optional": false,
                  "pattern": null, "admits": "Vocabulary::Doneness" }
            ] }
        ] } })
    }

    fn doneness_attribute(ir: &Value) -> Map<String, Value> {
        ir["Kitchen"]["aggregates"][1]["attributes"][0]
            .as_object()
            .cloned()
            .unwrap()
    }

    #[test]
    fn an_admitted_set_is_resolved_from_the_aggregate_that_declares_it() {
        let resolved = resolve_admitted_sets(kitchen());
        let admitted = doneness_attribute(&resolved);
        assert_eq!(
            admitted.get(ADMITTED).unwrap(),
            &serde_json::json!(["rare", "medium", "well"])
        );
    }

    /// The message is held to Ruby's WORD FOR WORD (`Value.admit_declared_set`).
    /// Two runtimes that refuse the same value for different reasons still read
    /// as a split to anyone diffing the output, which is what bin/parity does.
    #[test]
    fn a_non_member_is_refused_in_the_same_words_ruby_refuses_it() {
        let resolved = resolve_admitted_sets(kitchen());
        let attribute = doneness_attribute(&resolved);

        assert!(admit_declared_set(&attribute, &Value::String("medium".into())).is_ok());
        assert_eq!(
            admit_declared_set(&attribute, &Value::String("burnt".into())).unwrap_err(),
            "doneness admits Vocabulary::Doneness — \"rare\", \"medium\", \"well\" — got \"burnt\""
        );
    }

    /// A scalar arrives wrapped in whatever holder its type names, so the check
    /// has to see through the envelope — the bug this had on its first pass.
    #[test]
    fn a_value_wrapped_in_its_holder_is_read_through_to_the_scalar() {
        let resolved = resolve_admitted_sets(kitchen());
        let attribute = doneness_attribute(&resolved);
        let wrapped = serde_json::json!({ "value": "well" });

        assert!(admit_declared_set(&attribute, &wrapped).is_ok());
    }

    /// A link that resolves to nothing is refused rather than ignored: a rule
    /// checked against nothing reads like a rule and is not one.
    #[test]
    fn naming_a_set_the_chapter_does_not_declare_is_refused() {
        let mut attribute = doneness_attribute(&resolve_admitted_sets(kitchen()));
        attribute.insert("admits".into(), Value::String("Vocabulary::Nonesuch".into()));
        attribute.remove(ADMITTED);

        let refusal = admit_declared_set(&attribute, &Value::String("rare".into())).unwrap_err();
        assert!(refusal.contains("which this chapter does not declare"), "{refusal}");
    }
}
