//! sqlite_mapping — IR type → SQL type, and Value ↔ SQL cell mapping
//!
//! The parity-critical translation layer for the SQLite backend,
//! extracted from `sqlite_repository` to keep each file's concern
//! single (DDL/CRUD there ; type + cell mapping here).
//!
//! `sql_type` is the typed-columns contract : it mirrors Ruby's
//! `SqlMigrationGenerator#sql_type` / `SqlBoot` type map VERBATIM, so a
//! given bluebook attribute type produces the same SQL column type on
//! both runtimes.
//!
//!   sql_type("String")  => "VARCHAR(255)"
//!   sql_type("Title")   => "TEXT"   (value-object / unknown → else)

use storehouse::runtime::Value;

/// Quote a SQL identifier (table or column name) so a reserved word — `order`,
/// `group`, `select`, `user` — or any keyword is a legal identifier instead of
/// a syntax error. SQLite's standard double-quote form, with any embedded quote
/// doubled per the SQL spec. The identifiers reaching here are always internal
/// (a snake_cased aggregate name, or an IR-declared column already whitelisted
/// against the known column set), so this is a keyword-collision correctness
/// guard — the injection boundary is the `?N` bind params, not this.
pub fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Map a bluebook IR attribute type to its SQL column type. Verbatim
/// mirror of Ruby's `sql_type` : String→VARCHAR(255), Integer→INTEGER,
/// Float→REAL, Boolean (and the Ruby TrueClass/FalseClass aliases)→
/// BOOLEAN ; everything unrecognised (value objects, DateTime-ish
/// `published_at`) → TEXT, exactly Ruby's `else` branch.
pub fn sql_type(attr_type: &str) -> &'static str {
    match attr_type {
        "String" => "VARCHAR(255)",
        "Integer" => "INTEGER",
        "Float" => "REAL",
        "Boolean" | "TrueClass" | "FalseClass" => "BOOLEAN",
        _ => "TEXT",
    }
}

/// Map a runtime `Value` to a rusqlite bind value. Mirrors the heki
/// backend's `to_json` coverage : Str/Int/Bool/Null bind natively ;
/// List/Map fall back to their JSON string form (the typed-column
/// model has no nested-shape column, so composite attrs serialise).
pub(super) fn value_to_sql(val: &Value) -> rusqlite::types::Value {
    use rusqlite::types::Value as S;
    match val {
        Value::Str(s) => S::Text(s.clone()),
        Value::Int(n) => S::Integer(*n),
        Value::Bool(b) => S::Integer(if *b { 1 } else { 0 }),
        Value::Null => S::Null,
        Value::List(_) | Value::Map(_) => S::Text(composite_json(val)),
    }
}

/// Read a SQL column back into a runtime `Value`. Integers stay Int ;
/// reals/text/blobs hydrate as Str ; NULL → Null. The dynamic
/// AggregateState bag is string-leaning, so non-integer scalars become
/// Str (the heki backend's `from_json` is equally lenient).
pub(super) fn value_from_sql(row: &rusqlite::Row<'_>, idx: usize) -> Value {
    use rusqlite::types::ValueRef;
    match row.get_ref(idx) {
        Ok(ValueRef::Null) => Value::Null,
        Ok(ValueRef::Integer(n)) => Value::Int(n),
        Ok(ValueRef::Real(f)) => Value::Str(f.to_string()),
        Ok(ValueRef::Text(t)) => Value::Str(String::from_utf8_lossy(t).into_owned()),
        Ok(ValueRef::Blob(b)) => Value::Str(String::from_utf8_lossy(b).into_owned()),
        Err(_) => Value::Null,
    }
}

/// JSON-string fallback for composite (List/Map) attrs — the typed
/// column has no nested-shape representation, so they serialise.
fn composite_json(val: &Value) -> String {
    serde_json::to_string(&serde_value(val)).unwrap_or_default()
}

fn serde_value(val: &Value) -> serde_json::Value {
    match val {
        Value::Str(s) => serde_json::Value::String(s.clone()),
        Value::Int(n) => serde_json::json!(*n),
        Value::Bool(b) => serde_json::json!(*b),
        Value::Null => serde_json::Value::Null,
        Value::List(items) => serde_json::json!(items.iter().map(serde_value).collect::<Vec<_>>()),
        Value::Map(m) => serde_json::Value::Object(
            m.iter().map(|(k, v)| (k.clone(), serde_value(v))).collect(),
        ),
    }
}
