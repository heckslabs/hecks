//! value_bridge - serde_json::Value <-> storehouse::runtime::Value.
//!
//! GLUE, not knowledge. This runtime's interpreters carry state as
//! serde_json::Value ; the adapters cherry-picked from Hecks speak
//! runtime::Value and AggregateState. Rather than edit either side, the
//! conversion lives here — one file, no domain logic, easy to delete when the
//! interpreters move onto runtime::Value directly.
//!
//! Null has no runtime::Value case: Hecks models absence as `Value::Null`,
//! which IS a variant there, so the mapping is total in both directions.

use crate::runtime::{AggregateState, Value as RtValue};
use serde_json::{Map, Value as JsonValue};

pub fn to_runtime(value: &JsonValue) -> RtValue {
    match value {
        JsonValue::Null => RtValue::Null,
        JsonValue::Bool(b) => RtValue::Bool(*b),
        JsonValue::Number(n) => match n.as_i64() {
            Some(i) => RtValue::Int(i),
            // No Float case in runtime::Value - a non-integer rides as text,
            // the same way the heki backend stores it.
            None => RtValue::Str(n.to_string()),
        },
        JsonValue::String(s) => RtValue::Str(s.clone()),
        JsonValue::Array(items) => RtValue::List(items.iter().map(to_runtime).collect()),
        JsonValue::Object(map) => RtValue::Map(
            map.iter()
                .map(|(key, value)| (key.clone(), to_runtime(value)))
                .collect(),
        ),
    }
}

pub fn to_json(value: &RtValue) -> JsonValue {
    match value {
        RtValue::Null => JsonValue::Null,
        RtValue::Bool(b) => JsonValue::Bool(*b),
        RtValue::Int(i) => JsonValue::from(*i),
        RtValue::Str(s) => JsonValue::String(s.clone()),
        RtValue::List(items) => JsonValue::Array(items.iter().map(to_json).collect()),
        RtValue::Map(map) => {
            let mut out = Map::new();
            for (key, value) in map {
                out.insert(key.clone(), to_json(value));
            }
            JsonValue::Object(out)
        }
    }
}

/// One dispatched instance, as the adapters expect it.
pub fn to_state(id: &str, fields: &Map<String, JsonValue>) -> AggregateState {
    let mut state = AggregateState::new(id);
    for (key, value) in fields {
        state.set(key, to_runtime(value));
    }
    state
}

/// And back, for the interpreters.
pub fn from_state(state: &AggregateState) -> Map<String, JsonValue> {
    let mut fields = Map::new();
    for (key, value) in &state.fields {
        fields.insert(key.clone(), to_json(value));
    }
    fields
}
