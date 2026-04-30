fn from_json(val: &serde_json::Value) -> Value {
    match val {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() { Value::Int(i) }
            else { Value::Str(n.to_string()) }
        }
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Null => Value::Null,
        serde_json::Value::Array(a) => Value::List(a.iter().map(from_json).collect()),
        serde_json::Value::Object(m) => {
            Value::Map(m.iter().map(|(k, v)| (k.clone(), from_json(v))).collect())
        }
    }
}
