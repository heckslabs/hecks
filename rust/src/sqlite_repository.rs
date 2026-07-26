//! sqlite_repository - the persistence adapter, in Rust.
//!
//! The MIRROR of lib/hecksagain/adapters/sqlite.rb, table for table and column
//! for column. Both are driven by the same rule: THE SCHEMA IS A PROJECTION OF
//! THE AGGREGATE IR. One column per declared attribute, its SQL type derived
//! from the declared type, lists stored as JSON. Nothing about the table is
//! hand-written on either side, which is why the two agree without either
//! knowing about the other.
//!
//! The domain never learns any of this. The hecksagon says
//! `persisted_by("Sqlite")` and the runtime resolves it.

use crate::dispatcher::{array, storage_name};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params_from_iter, Connection};
use serde_json::{Map, Value};

pub struct SqliteRepository {
    connection: Connection,
}

impl SqliteRepository {
    pub fn open(path: &str) -> Result<Self, String> {
        if let Some(parent) = std::path::Path::new(path).parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("cannot create {:?}: {}", parent, e))?;
        }

        let connection = Connection::open(path).map_err(|e| format!("cannot open {}: {}", path, e))?;
        let repository = SqliteRepository { connection };
        repository.create_event_table()?;
        Ok(repository)
    }

    /// One column per declared attribute - the schema follows the IR.
    pub fn create_table(&self, aggregate: &Map<String, Value>) -> Result<(), String> {
        let table = table_name(aggregate);
        let columns: Vec<String> = array(aggregate, "attributes")
            .iter()
            .map(|attribute| format!("{} {}", column(attribute), sql_type(attribute)))
            .collect();

        let separator = if columns.is_empty() { "" } else { ", " };
        self.execute(&format!(
            "CREATE TABLE IF NOT EXISTS {} (id TEXT PRIMARY KEY{}{})",
            table,
            separator,
            columns.join(", ")
        ))
    }

    fn create_event_table(&self) -> Result<(), String> {
        self.execute(
            "CREATE TABLE IF NOT EXISTS events (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                name         TEXT NOT NULL,
                aggregate    TEXT NOT NULL,
                aggregate_id TEXT NOT NULL,
                payload      TEXT,
                occurred_at  TEXT
             )",
        )
    }

    pub fn find(&self, aggregate: &Map<String, Value>, id: &str) -> Option<Map<String, Value>> {
        let attributes = array(aggregate, "attributes");
        let columns: Vec<String> = attributes.iter().map(column).collect();
        if columns.is_empty() {
            return None;
        }

        let sql = format!(
            "SELECT {} FROM {} WHERE id = ?1",
            columns.join(", "),
            table_name(aggregate)
        );

        let mut statement = self.connection.prepare(&sql).ok()?;
        let mut rows = statement.query([id]).ok()?;
        let row = rows.next().ok()??;

        let mut state = Map::new();
        for (index, attribute) in attributes.iter().enumerate() {
            let raw: SqlValue = row.get(index).unwrap_or(SqlValue::Null);
            state.insert(column(attribute), decode(attribute, raw));
        }
        Some(state)
    }

    /// Every stored instance, id and state. The parity harness reports what the
    /// STORE holds, so when Sqlite is bound this is where the answer comes from
    /// - not from a cache that happens to agree with it.
    pub fn all(&self, aggregate: &Map<String, Value>) -> Vec<(String, Map<String, Value>)> {
        let attributes = array(aggregate, "attributes");
        let mut columns = vec!["id".to_string()];
        columns.extend(attributes.iter().map(column));

        let sql = format!(
            "SELECT {} FROM {} ORDER BY id",
            columns.join(", "),
            table_name(aggregate)
        );

        let mut statement = match self.connection.prepare(&sql) {
            Ok(statement) => statement,
            Err(_) => return vec![],
        };
        let mut rows = match statement.query([]) {
            Ok(rows) => rows,
            Err(_) => return vec![],
        };

        let mut found = vec![];
        while let Ok(Some(row)) = rows.next() {
            let id: String = row.get(0).unwrap_or_default();
            let mut state = Map::new();
            for (index, attribute) in attributes.iter().enumerate() {
                let raw: SqlValue = row.get(index + 1).unwrap_or(SqlValue::Null);
                state.insert(column(attribute), decode(attribute, raw));
            }
            found.push((id, state));
        }
        found
    }

    pub fn save(
        &self,
        aggregate: &Map<String, Value>,
        id: &str,
        state: &Map<String, Value>,
    ) -> Result<(), String> {
        let attributes = array(aggregate, "attributes");

        let mut columns = vec!["id".to_string()];
        let mut values: Vec<Option<String>> = vec![Some(id.to_string())];

        for attribute in &attributes {
            let name = column(attribute);
            values.push(encode(attribute, state.get(&name)));
            columns.push(name);
        }

        let slots: Vec<String> = (1..=columns.len()).map(|n| format!("?{}", n)).collect();
        let sql = format!(
            "INSERT OR REPLACE INTO {} ({}) VALUES ({})",
            table_name(aggregate),
            columns.join(", "),
            slots.join(", ")
        );

        self.connection
            .execute(&sql, params_from_iter(values.iter()))
            .map(|_| ())
            .map_err(|e| format!("cannot save {}: {}", id, e))
    }

    /// The event log is durable too - a purchase you cannot look up tomorrow
    /// was never really recorded.
    pub fn record_event(&self, event: &Value) -> Result<(), String> {
        let text = |key: &str| event.get(key).and_then(Value::as_str).unwrap_or("").to_string();
        let payload = event
            .get("payload")
            .map(|p| p.to_string())
            .unwrap_or_else(|| "{}".to_string());

        self.connection
            .execute(
                "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![text("name"), text("aggregate"), text("id"), payload, text("occurred_at")],
            )
            .map(|_| ())
            .map_err(|e| format!("cannot record event: {}", e))
    }

    fn execute(&self, sql: &str) -> Result<(), String> {
        self.connection
            .execute(sql, [])
            .map(|_| ())
            .map_err(|e| format!("{}: {}", sql, e))
    }
}

fn table_name(aggregate: &Map<String, Value>) -> String {
    storage_name(aggregate.get("name").and_then(Value::as_str).unwrap_or("aggregate"))
}

fn column(attribute: &Value) -> String {
    attribute
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn is_list(attribute: &Value) -> bool {
    attribute.get("list").and_then(Value::as_bool).unwrap_or(false)
}

/// Lists become JSON ; everything else takes the declared type's SQL kind.
fn sql_type(attribute: &Value) -> &'static str {
    if is_list(attribute) {
        return "TEXT";
    }
    match attribute.get("type").and_then(Value::as_str) {
        Some("Integer") => "INTEGER",
        Some("Float") => "REAL",
        _ => "TEXT",
    }
}

fn encode(attribute: &Value, value: Option<&Value>) -> Option<String> {
    let value = value.unwrap_or(&Value::Null);

    if is_list(attribute) {
        return Some(if value.is_null() {
            "[]".to_string()
        } else {
            value.to_string()
        });
    }

    match value {
        Value::Null => None,
        Value::String(text) => Some(text.clone()),
        other => Some(other.to_string()),
    }
}

/// Read a stored column back.
///
/// The COLUMN'S OWN TYPE decides. Asking sqlite for every column as a string
/// works right up until an INTEGER column, where the typed read fails and the
/// value silently becomes null — which is exactly how price_cents went missing
/// while the Rust side still ran without error. The parity harness caught it
/// the moment Rust started reading back from disk instead of a HashMap.
fn decode(attribute: &Value, raw: SqlValue) -> Value {
    if is_list(attribute) {
        let text = match raw {
            SqlValue::Text(text) => text,
            _ => "[]".to_string(),
        };
        return serde_json::from_str(&text).unwrap_or_else(|_| Value::Array(vec![]));
    }

    match raw {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(number) => Value::from(number),
        SqlValue::Real(number) => Value::from(number),
        SqlValue::Text(text) => Value::String(text),
        SqlValue::Blob(_) => Value::Null,
    }
}
