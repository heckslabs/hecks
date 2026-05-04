
/// i221-B — convert a serde_json::Map into a HashMap<String, Value>
/// for use as `iter_data` in a sweep dispatch. The sweep records come
/// from `resolve_query` which serializes through serde_json ; this
/// brings them back into the runtime's Value enum so `from_iter
/// (:field)` reads land in the right shape.
fn json_obj_to_value_map(map: serde_json::Map<String, serde_json::Value>) -> HashMap<String, Value> {
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
