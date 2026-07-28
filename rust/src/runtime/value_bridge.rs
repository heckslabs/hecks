
use crate::runtime::{AggregateState, Value as RtValue};
use serde_json::{Map, Value as JsonValue};

pub fn to_runtime(value: &JsonValue) -> RtValue {
    match value {
        JsonValue::Null => RtValue::Null,
        JsonValue::Bool(b) => RtValue::Bool(*b),
        JsonValue::Number(n) => match n.as_i64() {
            Some(i) => RtValue::Int(i),
            None => match n.as_f64() {
                Some(f) => RtValue::Float(f),
                None => RtValue::Str(n.to_string()),
            },
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
        RtValue::Float(f) => JsonValue::from(*f),
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

pub fn to_state(id: &str, fields: &Map<String, JsonValue>) -> AggregateState {
    let mut state = AggregateState::new(id);
    for (key, value) in fields {
        state.set(key, to_runtime(value));
    }
    state
}

pub fn from_state(state: &AggregateState) -> Map<String, JsonValue> {
    let mut fields = Map::new();
    for (key, value) in &state.fields {
        fields.insert(key.clone(), to_json(value));
    }
    fields
}
