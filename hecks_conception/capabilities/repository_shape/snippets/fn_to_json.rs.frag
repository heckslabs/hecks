fn to_json(val: &Value) -> serde_json::Value {
    match val {
        Value::Str(s) => serde_json::Value::String(s.clone()),
        Value::Int(n) => serde_json::json!(*n),
        Value::Bool(b) => serde_json::json!(*b),
        Value::Null => serde_json::Value::Null,
        Value::List(items) => serde_json::json!(items.iter().map(to_json).collect::<Vec<_>>()),
        Value::Map(m) => {
            let obj: serde_json::Map<String, serde_json::Value> =
                m.iter().map(|(k, v)| (k.clone(), to_json(v))).collect();
            serde_json::Value::Object(obj)
        }
    }
}
