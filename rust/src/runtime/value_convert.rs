
use super::*;

pub(super) fn parse_payload_attrs(json: &str) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    if let Ok(serde_json::Value::Object(obj)) = serde_json::from_str::<serde_json::Value>(json) {
        for (k, v) in obj {
            let val = match v {
                serde_json::Value::String(s) => Value::Str(s),
                serde_json::Value::Bool(b) => Value::Bool(b),
                serde_json::Value::Number(n) => n.as_i64().map(Value::Int).unwrap_or(Value::Null),
                serde_json::Value::Null => Value::Null,
                other => Value::Str(other.to_string()),
            };
            out.insert(k, val);
        }
    }
    out
}


pub(crate) fn value_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Str(s) => serde_json::json!(s),
        Value::Int(n) => serde_json::json!(n),
        Value::Bool(b) => serde_json::json!(b),
        Value::List(items) => serde_json::Value::Array(items.iter().map(value_to_json).collect()),
        Value::Map(m) => {
            let mut o = serde_json::Map::new();
            for (k, val) in m {
                o.insert(k.clone(), value_to_json(val));
            }
            serde_json::Value::Object(o)
        }
        Value::Null => serde_json::Value::Null,
    }
}

pub fn value_to_json_string(v: &Value) -> String {
    value_to_json(v).to_string()
}

pub fn value_from_json_str(s: &str) -> Value {
    match serde_json::from_str::<serde_json::Value>(s) {
        Ok(jv) => json_to_value_recursive(&jv),
        Err(_) => Value::Str(s.to_string()),
    }
}

pub fn attr_value_from_str(raw: &str) -> Value {
    let t = raw.trim();
    if (t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']')) {
        if let Ok(jv) = serde_json::from_str::<serde_json::Value>(t) {
            return json_to_value_recursive(&jv);
        }
    }
    Value::Str(raw.to_string())
}

pub(super) fn json_to_value_recursive(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(i) => Value::Int(i),
            None => Value::Str(n.to_string()),
        },
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Array(a) => {
            Value::List(a.iter().map(json_to_value_recursive).collect())
        }
        serde_json::Value::Object(m) => {
            Value::Map(m.iter().map(|(k, v)| (k.clone(), json_to_value_recursive(v))).collect())
        }
    }
}

impl Value {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(n) => Some(*n),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&Vec<Value>> {
        match self {
            Value::List(v) => Some(v),
            _ => None,
        }
    }
}

impl std::fmt::Display for Value {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Value::Str(s) => write!(f, "{}", s),
            Value::Int(n) => write!(f, "{}", n),
            Value::Bool(b) => write!(f, "{}", b),
            Value::List(v) => write!(f, "[{} items]", v.len()),
            Value::Map(m) => write!(f, "{{{} fields}}", m.len()),
            Value::Null => write!(f, "null"),
        }
    }
}


pub(super) fn json_obj_to_value_map(map: serde_json::Map<String, serde_json::Value>) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for (k, v) in map {
        let value = match v {
            serde_json::Value::String(s) => Value::Str(s),
            serde_json::Value::Bool(b)   => Value::Bool(b),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() { Value::Int(i) } else { Value::Str(n.to_string()) }
            }
            serde_json::Value::Null      => Value::Null,
            other                        => Value::Str(other.to_string()),
        };
        out.insert(k, value);
    }
    out
}
