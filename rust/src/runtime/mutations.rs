use crate::bluebook::expression::resolver::describe;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::ir::{Aggregate, Attribute, Command, Entity, Mutation, MutationOp, ValueObject};
use crate::runtime::refusal_wording;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::sync::LazyLock;

// increment/decrement share one arithmetic primitive, differing only by
// sign — the same reduction Vocabulary::Comparison's algebra is for the six
// comparison operators. The language declares it in Vocabulary::MutationOp
// (language/bluebook.bluebook) ; Ruby's copy (CommandRules::MUTATION_OPS) is
// held equal to the language by spec/vocabulary_conformance_spec ; this
// file's copy is that table's JSON export, embedded at compile time.
// Regenerate with `bin/mutation_ops > rust/src/runtime/mutation_ops.json`
// any time MUTATION_OPS changes.
struct MutationOpSign {
    name: String,
    sign: Option<i64>,
}

static MUTATION_OPS_JSON: &str = include_str!("mutation_ops.json");

static MUTATION_OPS: LazyLock<Vec<MutationOpSign>> = LazyLock::new(|| {
    let parsed: Value =
        serde_json::from_str(MUTATION_OPS_JSON).expect("mutation_ops.json must parse as JSON");
    parsed
        .as_array()
        .expect("mutation_ops.json must hold an array")
        .iter()
        .map(|row| MutationOpSign {
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

/// A closed-set-or-literal declaration parsed straight off its RAW
/// declaration text — `Attribute.default` and `Mutation.source` (the
/// non-argument case) both hold exactly what the bluebook wrote, unparsed.
/// Mirrors `ir_json::literal` byte for byte : that function exists to give
/// the WIRE the same reading, and reusing the derivation here (rather than
/// re-deriving it) is what keeps the two guaranteed to agree rather than
/// merely hoped to.
fn parse_literal(text: &str) -> Value {
    let text = text.trim();
    if text.is_empty() {
        return Value::Null;
    }
    if text.len() >= 2 && text.starts_with('"') && text.ends_with('"') {
        return Value::String(text[1..text.len() - 1].to_string());
    }
    if text.starts_with('{') && text.ends_with('}') {
        let mut map = Map::new();
        for entry in text[1..text.len() - 1].split(',') {
            let Some((key, value)) = entry.split_once(':') else {
                continue;
            };
            let key = key.trim().trim_start_matches(':').trim_matches('"');
            if !key.is_empty() {
                map.insert(key.to_string(), parse_literal(value.trim()));
            }
        }
        return Value::Object(map);
    }
    if let Ok(number) = text.parse::<i64>() {
        return Value::from(number);
    }
    if let Ok(number) = text.parse::<f64>() {
        return Value::from(number);
    }
    match text {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        "nil" | "null" => Value::Null,
        other => Value::String(other.to_string()),
    }
}

pub fn defaults_for(aggregate: &Aggregate, admitted_sets: &HashMap<String, Vec<String>>) -> Result<State, String> {
    let mut state = Map::new();

    for attribute in &aggregate.attributes {
        let value = if attribute.list {
            Value::Array(Vec::new())
        } else {
            default_value(aggregate, attribute, admitted_sets)?
        };
        state.insert(attribute.name.clone(), value);
    }

    if let Some(lifecycle) = &aggregate.lifecycle {
        state.insert(lifecycle.field.clone(), Value::String(lifecycle.default.clone()));
    }
    Ok(state)
}

fn default_value(
    aggregate: &Aggregate,
    attribute: &Attribute,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<Value, String> {
    // A declared default is read through `parse_literal` the same way the
    // WIRE would read it (`ir_json::literal`) — including the possibility
    // that the declared text itself spells "nil"/"null"/"" and parses BACK
    // to Null, which counts as no default just as an absent one does.
    let declared_default = attribute.default.as_deref().map(parse_literal).unwrap_or(Value::Null);
    if !declared_default.is_null() {
        return coerce_attribute(aggregate, attribute, &declared_default, admitted_sets);
    }

    let Some(value_object) = value_object_named(aggregate, &attribute.r#type) else {
        return Ok(Value::Null);
    };
    let all_fields_default = value_object.attributes.iter().all(|field| {
        !field.default.as_deref().map(parse_literal).unwrap_or(Value::Null).is_null()
    });
    if !all_fields_default {
        return Ok(Value::Null);
    }

    coerce_attribute(aggregate, attribute, &Value::Object(Map::new()), admitted_sets)
}

pub fn assign_creation_attributes(
    state: &mut State,
    aggregate: &Aggregate,
    command: &Command,
    args: &State,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<(), String> {
    let declared: Vec<&str> = aggregate.attributes.iter().map(|a| a.name.as_str()).collect();

    for attribute in &command.attributes {
        if !declared.contains(&attribute.name.as_str()) {
            continue;
        }
        if let Some(value) = args.get(&attribute.name) {
            let coerced = coerce(aggregate, &attribute.name, value, admitted_sets)?;
            state.insert(attribute.name.clone(), coerced);
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
    aggregate: &Aggregate,
    command: &Command,
    args: &State,
    correlation: &[String],
) -> Result<(), String> {
    let mut known: Vec<String> = command.attributes.iter().map(|a| a.name.clone()).collect();
    let declared = known.join(", ");

    known.push("id".to_string());
    // THE HEADS, not the paths — `identified_by { symbol.value }` means a caller
    // passes `symbol:`, and admitting "symbol.value" would refuse it as
    // undeclared. EVERY head, because a composite identity is addressed by all
    // its parts: admitting only the first refused `number:` on a stall the
    // caller had named correctly, and named the argument undeclared when the
    // bluebook declares it as half the identity.
    known.extend(
        crate::identity::heads_of_paths(&aggregate.identified_by)
            .into_iter()
            .map(str::to_string),
    );
    if let Some(target) = &command.references {
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

    let unknown_joined = unknown.join(", ");
    Err(refusal_wording::render(
        "UnknownArgument",
        "unknown_args",
        &[("command", &command.name), ("unknown", &unknown_joined), ("declared", &declared)],
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
pub fn refuse_absent_arguments(command: &Command, args: &State) -> Result<(), String> {
    let declared: Vec<&str> = command.attributes.iter().map(|a| a.name.as_str()).collect();

    // SORTED, for the same reason the unknown list is : declaration order is stable
    // but the two runtimes reach it differently, and a refusal has to read
    // identically in both or parity says so.
    let required: Vec<&str> = command
        .attributes
        .iter()
        .filter(|attribute| !attribute.optional)
        .map(|a| a.name.as_str())
        .collect();

    let mut absent: Vec<&str> = required
        .iter()
        .copied()
        .filter(|name| !args.contains_key(*name))
        .collect();
    absent.sort_unstable();
    if absent.is_empty() {
        return Ok(());
    }

    let absent_joined = absent.join(", ");
    let declared_joined = declared.join(", ");
    Err(refusal_wording::render(
        "AbsentArgument",
        "absent_args",
        &[("command", &command.name), ("absent", &absent_joined), ("declared", &declared_joined)],
    ))
}

pub fn normalize_command_args(
    aggregate: &Aggregate,
    command: &Command,
    args: &State,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<State, String> {
    let mut normalized = args.clone();
    for attribute in &command.attributes {
        let Some(value) = normalized.get(&attribute.name).cloned() else {
            continue;
        };
        normalized.insert(attribute.name.clone(), coerce_attribute(aggregate, attribute, &value, admitted_sets)?);
    }
    Ok(normalized)
}

fn coerce(
    aggregate: &Aggregate,
    name: &str,
    value: &Value,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<Value, String> {
    let Some(attribute) = aggregate.attributes.iter().find(|a| a.name == name) else {
        return Ok(value.clone());
    };
    coerce_attribute(aggregate, attribute, value, admitted_sets)
}

pub fn coerce_attribute(
    aggregate: &Aggregate,
    attribute: &Attribute,
    value: &Value,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<Value, String> {
    if attribute.list {
        return Ok(value.clone());
    }
    let Some(value_object) = value_object_named(aggregate, &attribute.r#type) else {
        // A PLAIN FIELD STILL ADMITS WHAT IT SAYS IT ADMITS. Nothing to coerce
        // here — no value object names this type — but the set is named on the
        // attribute, not on the type, so the refusal belongs on this path too.
        admit_declared_set(attribute, value, admitted_sets)?;
        return Ok(value.clone());
    };
    if value.is_null() {
        return Ok(value.clone());
    }
    if let Some(object) = value.as_object() {
        let mut completed = object.clone();
        for field in &value_object.attributes {
            if !completed.contains_key(&field.name) {
                let default = field.default.as_deref().map(parse_literal).unwrap_or(Value::Null);
                if !default.is_null() {
                    completed.insert(field.name.clone(), default);
                }
            }
        }
        admit_member(&value_object, &completed)?;
        check_admitted(&value_object, &completed, admitted_sets)?;
        check_numeric_fields(&value_object, &completed)?;
        check_patterns(&value_object, &completed)?;
        enforce_invariants(&value_object, &completed)?;
        // AFTER coercion, not before: a scalar arrives wrapped in whatever
        // holder its type names, and checking the raw payload would be checking
        // the envelope.
        let coerced = Value::Object(completed);
        admit_declared_set(attribute, &coerced, admitted_sets)?;
        return Ok(coerced);
    }

    let offered = value.to_string();
    Err(refusal_wording::render(
        "TypeMismatch",
        "value_object_shape",
        &[("name", &attribute.name), ("type", &value_object.name), ("offered", &offered)],
    ))
}

pub fn apply_mutation(
    state: &mut State,
    aggregate: &Aggregate,
    mutation: &Mutation,
    args: &State,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<(), String> {
    match mutation.op {
        MutationOp::Append => {
            let mut items = state
                .get(&mutation.target)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let element = build_element(aggregate, &mutation.target, mutation, args, items.len(), admitted_sets)?;
            items.push(element);
            state.insert(mutation.target.clone(), Value::Array(items));
        }
        MutationOp::Increment | MutationOp::Decrement => {
            let operation = if matches!(mutation.op, MutationOp::Increment) { "increment" } else { "decrement" };
            let updated = arithmetic(state, &mutation.target, operation, mutation, args)?;
            state.insert(mutation.target.clone(), updated);
        }
        MutationOp::Set => {
            let value = resolve_source(mutation, args);
            let coerced = coerce(aggregate, &mutation.target, &value, admitted_sets)?;
            state.insert(mutation.target.clone(), coerced);
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
    mutation: &Mutation,
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

/// `mutation.source`, AS DECLARED — a leading `:` means an argument the
/// command's payload carries, anything else is a literal read the same way
/// `Attribute.default` is (`parse_literal`, mirroring `ir_json::literal`).
pub fn resolve_source(mutation: &Mutation, args: &State) -> Value {
    let text = mutation.source.trim();
    if let Some(name) = text.strip_prefix(':') {
        return args.get(name).cloned().unwrap_or(Value::Null);
    }
    parse_literal(text)
}

/// One `field: token` pair out of an `append: { ... }` mapping's declared
/// source text — mirrors the round trip `ir_json::mutation_to_value`'s
/// Append branch and this file's own JSON-path `build_element` used to make
/// together (write the argument out as Ruby-hash-literal text, then read it
/// back in), collapsed into reading the declaration directly. A TOP-LEVEL
/// token is an argument name, a quoted string, or an integer ; a NESTED
/// `{...}` value is read through to a plain string field for field, same as
/// the old read side did — no further coercion, no argument lookup inside
/// it. That asymmetry is not a shortcut taken here : it is what the two-step
/// text round trip already did, so preserving it is what keeps `direction: {
/// value: "credit" }` reading the same value it always has.
fn append_field_value(raw_argument: &str, args: &State) -> Value {
    let argument = raw_argument.trim().trim_start_matches(':').trim();

    if argument.starts_with('{') && argument.ends_with('}') {
        let mut fields = Map::new();
        for pair in argument[1..argument.len() - 1].split(',') {
            let Some((key, value)) = pair.split_once(':') else {
                continue;
            };
            let key = key.trim();
            if key.is_empty() {
                continue;
            }
            let value = value.trim().trim_matches('"');
            fields.insert(key.to_string(), Value::String(value.to_string()));
        }
        return Value::Object(fields);
    }

    if argument.len() >= 2 && argument.starts_with('"') && argument.ends_with('"') {
        return Value::String(argument[1..argument.len() - 1].to_string());
    }
    if let Ok(number) = argument.parse::<i64>() {
        return Value::from(number);
    }
    args.get(argument).cloned().unwrap_or(Value::Null)
}

fn build_element(
    aggregate: &Aggregate,
    target: &str,
    mutation: &Mutation,
    args: &State,
    current_len: usize,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<Value, String> {
    let mut fields = Map::new();

    let body = mutation.source.trim().trim_start_matches('{').trim_end_matches('}');
    for pair in body.split(',') {
        let Some((field, argument)) = pair.split_once(':') else {
            continue;
        };
        let field = field.trim();
        let argument = argument.trim();
        if field.is_empty() || argument.is_empty() {
            continue;
        }
        fields.insert(field.to_string(), append_field_value(argument, args));
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
        if let [key] = crate::identity::heads_of_paths(&entity.identified_by)[..] {
            if !fields.contains_key(key) {
                let generated = Value::from(current_len as i64 + 1);
                let identity_attribute = entity.attributes.iter().find(|a| a.name == key);
                let value = identity_attribute
                    .and_then(|attribute| value_object_named(aggregate, &attribute.r#type))
                    .and_then(|value_object| {
                        let field = value_object.attributes.first()?.name.clone();
                        Some(Value::Object(Map::from_iter([(field, generated.clone())])))
                    })
                    .unwrap_or(generated);
                fields.insert(key.to_string(), value);
            }
        }
        if let Some(lifecycle) = &entity.lifecycle {
            fields
                .entry(lifecycle.field.clone())
                .or_insert_with(|| Value::String(lifecycle.default.clone()));
        }

        for attribute in &entity.attributes {
            let Some(value) = fields.get(&attribute.name).cloned() else {
                continue;
            };
            fields.insert(attribute.name.clone(), coerce_attribute(aggregate, attribute, &value, admitted_sets)?);
        }
    }

    if let Some(value_object) = value_object_for(aggregate, target) {
        flatten_scalar_fields(aggregate, &value_object, &mut fields);
        admit_member(&value_object, &fields)?;
        check_admitted(&value_object, &fields, admitted_sets)?;
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
fn check_numeric_fields(value_object: &ValueObject, fields: &Map<String, Value>) -> Result<(), String> {
    for attribute in &value_object.attributes {
        let numeric = match attribute.r#type.as_str() {
            "Integer" => true,
            "Float" => true,
            _ => continue,
        };
        let Some(given) = fields.get(&attribute.name) else { continue };
        if given.is_null() {
            continue;
        }
        let ok = if attribute.r#type == "Integer" {
            given.is_i64() || given.is_u64()
        } else {
            given.is_number()
        };
        if numeric && !ok {
            let offered = render_scalar(given);
            return Err(refusal_wording::render(
                "TypeMismatch",
                "numeric_field",
                &[("type", &value_object.name), ("field", &attribute.name), ("expected", &attribute.r#type), ("offered", &offered)],
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
fn check_patterns(value_object: &ValueObject, fields: &Map<String, Value>) -> Result<(), String> {
    for attribute in &value_object.attributes {
        let Some(pattern) = attribute.pattern.as_deref() else {
            continue;
        };
        let Some(given) = fields.get(&attribute.name) else { continue };
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
                &[("type", &value_object.name), ("field", &attribute.name), ("pattern", pattern), ("offered", &offered)],
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
fn flatten_scalar_fields(aggregate: &Aggregate, value_object: &ValueObject, fields: &mut Map<String, Value>) {
    for attribute in &value_object.attributes {
        let declared_scalar = value_object_named(aggregate, &attribute.r#type).is_none();
        if !declared_scalar {
            continue;
        }
        let Some(Value::Object(supplied)) = fields.get(&attribute.name) else {
            continue;
        };
        if supplied.len() != 1 {
            continue;
        }
        let Some(scalar) = supplied.values().next().cloned() else {
            continue;
        };
        fields.insert(attribute.name.clone(), scalar);
    }
}

/// Every closed set the chapter declares, keyed the way an `admits` names
/// it — read off `crate::ir::Domain` directly. Computed once at
/// `Runtime::new` and held on `Runtime.admitted_sets`, threaded through
/// every coercion/admission function below rather than read off a JSON
/// annotation : `admit_declared_set`'s callers used to read a
/// `admitted_members` field the JSON `ir` was annotated with after the fact
/// (M6a's `resolve_admitted_sets`) ; M6b moved every one of them here, so
/// that annotation step is gone from `Runtime::new` and this is the only
/// derivation left.
pub fn admitted_sets_of_domain(domain: &crate::ir::Domain) -> std::collections::HashMap<String, Vec<String>> {
    let mut sets = std::collections::HashMap::new();
    for aggregate in &domain.aggregates {
        for value_object in &aggregate.value_objects {
            let members = admitted_values_typed(value_object);
            if members.is_empty() {
                continue;
            }
            sets.insert(format!("{}::{}", aggregate.name, value_object.name), members);
        }
    }
    sets
}

/// The values a closed set admits, read through its discriminant — the first
/// field, which is what a member row is keyed by.
fn admitted_values_typed(value_object: &crate::ir::ValueObject) -> Vec<String> {
    if value_object.members.is_empty() {
        return vec![];
    }
    let Some(discriminant) = value_object.attributes.first().map(|a| a.name.clone()) else {
        return vec![];
    };
    value_object
        .members
        .iter()
        .filter_map(|pairs| {
            pairs
                .iter()
                .find(|(field, _)| *field == discriminant)
                .map(|(_, value)| value.clone())
        })
        .collect()
}

/// Mirrors Ruby's `Value.admit_declared_set` (`lib/hecksagain/runtime/value.rb`).
///
/// `admit_member` below refuses a non-member when the value object BEING BUILT
/// is itself the closed set. This is the other direction: the value is ordinary
/// text and the set it must belong to was declared once, elsewhere, and named.
fn admit_declared_set(
    attribute: &Attribute,
    value: &Value,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<(), String> {
    let Some(named) = attribute.admits.as_deref() else {
        return Ok(());
    };
    if value.is_null() {
        return Ok(());
    }
    let Some(admitted) = admitted_sets.get(named) else {
        return Err(refusal_wording::render(
            "InvariantViolation",
            "undeclared_set",
            &[("name", &attribute.name), ("admits", named)],
        ));
    };
    let offered = admitted_scalar(value);
    let offered_text = match &offered {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    };
    if admitted.iter().any(|value| value == &offered_text) {
        return Ok(());
    }
    let rendered: Vec<String> = admitted.iter().map(|value| format!("{value:?}")).collect();
    let got = match &offered {
        Value::String(text) => format!("{text:?}"),
        Value::Null => "nil".to_string(),
        other => other.to_string(),
    };
    let rendered_joined = rendered.join(", ");
    Err(refusal_wording::render(
        "InvariantViolation",
        "admits_declared_set",
        &[("name", &attribute.name), ("admits", named), ("admitted", &rendered_joined), ("offered", &got)],
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
    value_object: &ValueObject,
    fields: &Map<String, Value>,
    admitted_sets: &HashMap<String, Vec<String>>,
) -> Result<(), String> {
    for attribute in &value_object.attributes {
        if attribute.admits.is_none() {
            continue;
        }
        admit_declared_set(attribute, &fields.get(&attribute.name).cloned().unwrap_or(Value::Null), admitted_sets)?;
    }
    Ok(())
}

fn admit_member(value_object: &ValueObject, fields: &Map<String, Value>) -> Result<(), String> {
    if value_object.members.is_empty() {
        return Ok(());
    }
    let Some(discriminant) = value_object.attributes.first().map(|a| a.name.clone()) else {
        return Ok(());
    };
    let admitted: Vec<String> = value_object
        .members
        .iter()
        .filter_map(|pairs| {
            pairs
                .iter()
                .find(|(field, _)| *field == discriminant)
                .map(|(_, value)| value.clone())
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
        &[("type", &value_object.name), ("admitted", &rendered_joined), ("offered", &got)],
    ))
}

fn enforce_invariants(value_object: &ValueObject, fields: &Map<String, Value>) -> Result<(), String> {
    let empty = Map::new();
    for invariant in &value_object.invariants {
        let canonical = crate::projector::ir_json::canonicalise(&invariant.canonical);
        if evaluate_given(&canonical, fields, &empty)? {
            continue;
        }
        return Err(format!(
            "{} invariant violated — {} (given {})",
            value_object.name,
            invariant.description,
            Value::Object(fields.clone())
        ));
    }
    Ok(())
}

pub fn entity_for<'a>(aggregate: &'a Aggregate, target: &str) -> Option<&'a Entity> {
    let element_type = aggregate.attributes.iter().find(|a| a.name == target)?.r#type.as_str();
    aggregate.entities.iter().find(|e| e.name == element_type)
}

fn value_object_named<'a>(aggregate: &'a Aggregate, name: &str) -> Option<&'a ValueObject> {
    aggregate.value_objects.iter().find(|v| v.name == name)
}

fn value_object_for<'a>(aggregate: &'a Aggregate, target: &str) -> Option<&'a ValueObject> {
    let element_type = aggregate.attributes.iter().find(|a| a.name == target)?.r#type.as_str();
    value_object_named(aggregate, element_type)
}

#[cfg(test)]
mod admitted_sets_typed_tests {
    use super::*;
    use crate::ir::{Attribute, Domain, ValueObject};

    /// The TYPED twin of `sign_tests::kitchen()` below — same closed set,
    /// same cross-aggregate `admits` link, built from `crate::ir::Domain`
    /// structs instead of JSON, so `admitted_sets_of_domain` can be proven
    /// against a real typed shape rather than only against itself.
    fn kitchen_domain() -> Domain {
        let doneness = ValueObject {
            name: "Doneness".to_string(),
            attributes: vec![Attribute {
                name: "name".to_string(),
                r#type: "String".to_string(),
                default: None,
                list: false,
                optional: false,
                enum_values: vec![],
                pattern: None,
                admits: None,
            }],
            invariants: vec![],
            members: vec![
                vec![("name".to_string(), "rare".to_string())],
                vec![("name".to_string(), "medium".to_string())],
                vec![("name".to_string(), "well".to_string())],
            ],
            closed_set: true,
        };
        let vocabulary = crate::ir::Aggregate {
            name: "Vocabulary".to_string(),
            description: None,
            identified_by: vec![],
            attributes: vec![],
            lifecycle: None,
            commands: vec![],
            queries: vec![],
            value_objects: vec![doneness],
            entities: vec![],
        };
        let steak = crate::ir::Aggregate {
            name: "Steak".to_string(),
            description: None,
            identified_by: vec![],
            attributes: vec![Attribute {
                name: "doneness".to_string(),
                r#type: "String".to_string(),
                default: None,
                list: false,
                optional: false,
                enum_values: vec![],
                pattern: None,
                admits: Some("Vocabulary::Doneness".to_string()),
            }],
            lifecycle: None,
            commands: vec![],
            queries: vec![],
            value_objects: vec![],
            entities: vec![],
        };
        Domain {
            name: "Kitchen".to_string(),
            vision: None,
            classification: None,
            version: None,
            aggregates: vec![vocabulary, steak],
            policies: vec![],
            process_managers: vec![],
            read_models: vec![],
        }
    }

    #[test]
    fn resolves_a_closed_set_declared_in_a_sibling_aggregate() {
        let sets = admitted_sets_of_domain(&kitchen_domain());
        assert_eq!(
            sets.get("Vocabulary::Doneness"),
            Some(&vec!["rare".to_string(), "medium".to_string(), "well".to_string()])
        );
    }

    #[test]
    fn a_value_object_with_no_one_of_admits_nothing() {
        let mut domain = kitchen_domain();
        domain.aggregates[0].value_objects[0].members = vec![];
        let sets = admitted_sets_of_domain(&domain);
        assert!(!sets.contains_key("Vocabulary::Doneness"));
    }

    fn doneness_attribute(domain: &Domain) -> Attribute {
        domain.aggregates[1].attributes[0].clone()
    }

    /// The message is held to Ruby's WORD FOR WORD (`Value.admit_declared_set`).
    /// Two runtimes that refuse the same value for different reasons still read
    /// as a split to anyone diffing the output, which is what bin/parity does.
    #[test]
    fn a_non_member_is_refused_in_the_same_words_ruby_refuses_it() {
        let domain = kitchen_domain();
        let attribute = doneness_attribute(&domain);
        let admitted_sets = admitted_sets_of_domain(&domain);

        assert!(admit_declared_set(&attribute, &Value::String("medium".into()), &admitted_sets).is_ok());
        assert_eq!(
            admit_declared_set(&attribute, &Value::String("burnt".into()), &admitted_sets).unwrap_err(),
            "doneness admits Vocabulary::Doneness — \"rare\", \"medium\", \"well\" — got \"burnt\""
        );
    }

    /// A scalar arrives wrapped in whatever holder its type names, so the check
    /// has to see through the envelope — the bug this had on its first pass.
    #[test]
    fn a_value_wrapped_in_its_holder_is_read_through_to_the_scalar() {
        let domain = kitchen_domain();
        let attribute = doneness_attribute(&domain);
        let admitted_sets = admitted_sets_of_domain(&domain);
        let wrapped = serde_json::json!({ "value": "well" });

        assert!(admit_declared_set(&attribute, &wrapped, &admitted_sets).is_ok());
    }

    /// A link that resolves to nothing is refused rather than ignored: a rule
    /// checked against nothing reads like a rule and is not one.
    #[test]
    fn naming_a_set_the_chapter_does_not_declare_is_refused() {
        let domain = kitchen_domain();
        let mut attribute = doneness_attribute(&domain);
        attribute.admits = Some("Vocabulary::Nonesuch".to_string());
        // Named but never declared : the admitted_sets table built for THIS
        // domain has no such key, matching a chapter that never declares it.
        let admitted_sets = admitted_sets_of_domain(&domain);

        let refusal = admit_declared_set(&attribute, &Value::String("rare".into()), &admitted_sets).unwrap_err();
        assert!(refusal.contains("which this chapter does not declare"), "{refusal}");
    }
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
