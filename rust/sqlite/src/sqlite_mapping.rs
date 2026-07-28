
use storehouse::runtime::Value;

pub fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

pub fn sql_type(attr_type: &str) -> &'static str {
    match attr_type {
        "String" => "VARCHAR(255)",
        "Integer" => "INTEGER",
        "Float" => "REAL",
        "Boolean" | "TrueClass" | "FalseClass" => "BOOLEAN",
        _ => "TEXT",
    }
}

pub(super) fn value_to_sql(val: &Value) -> rusqlite::types::Value {
    use rusqlite::types::Value as S;
    match val {
        Value::Str(s) => S::Text(s.clone()),
        Value::Int(n) => S::Integer(*n),
        Value::Float(f) => S::Real(*f),
        Value::Bool(b) => S::Integer(if *b { 1 } else { 0 }),
        Value::Null => S::Null,
        Value::List(_) | Value::Map(_) => S::Text(composite_json(val)),
    }
}

pub(super) fn value_from_sql(row: &rusqlite::Row<'_>, idx: usize) -> Value {
    use rusqlite::types::ValueRef;
    match row.get_ref(idx) {
        Ok(ValueRef::Null) => Value::Null,
        Ok(ValueRef::Integer(n)) => Value::Int(n),
        Ok(ValueRef::Real(f)) => Value::Float(f),
        Ok(ValueRef::Text(t)) => Value::Str(String::from_utf8_lossy(t).into_owned()),
        Ok(ValueRef::Blob(b)) => Value::Str(String::from_utf8_lossy(b).into_owned()),
        Err(_) => Value::Null,
    }
}

fn composite_json(val: &Value) -> String {
    serde_json::to_string(&serde_value(val)).unwrap_or_default()
}

fn serde_value(val: &Value) -> serde_json::Value {
    match val {
        Value::Str(s) => serde_json::Value::String(s.clone()),
        Value::Int(n) => serde_json::json!(*n),
        Value::Float(f) => serde_json::json!(*f),
        Value::Bool(b) => serde_json::json!(*b),
        Value::Null => serde_json::Value::Null,
        Value::List(items) => serde_json::json!(items.iter().map(serde_value).collect::<Vec<_>>()),
        Value::Map(m) => serde_json::Value::Object(
            m.iter().map(|(k, v)| (k.clone(), serde_value(v))).collect(),
        ),
    }
}
