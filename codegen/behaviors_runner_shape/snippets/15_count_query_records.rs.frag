/// Count records in a resolve_query result. The result shape is
/// `{ "state": [..] }` for multi-record, `{ "state": {..} }` for one,
/// or `{ "state": [] }` for none.
fn count_query_records(result: &serde_json::Value) -> usize {
    match result.get("state") {
        Some(serde_json::Value::Array(a)) => a.len(),
        Some(serde_json::Value::Object(_)) => 1,
        _ => 0,
    }
}
