//! Repository — in-memory aggregate storage with heki persistence
//!
//! Stores AggregateState instances by id. On every save, upserts
//! to a .heki store so state is shared with Miette's organs.
//!
//! Id dispatch (id_for_command): driven entirely by `identified_by`
//! from the aggregate IR — no defaults, no singleton fallback.
//!
//! Callers must always supply the id explicitly:
//!   identified_by :name  → pass name=heartbeat in command attrs
//!   identified_by :ref   → pass ref=abc123 in command attrs
//!
//! Without identified_by, mints a u64 counter on creation.
//!
//! Usage:
//!   let repo = Repository::new("Heartbeat", data_dir, Some("name".into()));
//!
//! [antibody-exempt: runtime aggregate store; identified_by dispatch drives natural-key vs counter-mint (i80)]

use super::AggregateState;
use super::Value;
use crate::heki;
use std::collections::HashMap;

pub struct Repository {
    store: HashMap<String, AggregateState>,
    next_id: u64,
    aggregate_type: String,
    data_dir: Option<String>,
    identified_by: Option<String>,
}

impl Repository {
    pub fn new(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
    ) -> Self {
        let mut repo = Repository {
            store: HashMap::new(),
            next_id: 1,
            aggregate_type: aggregate_type.to_string(),
            data_dir,
            identified_by,
        };
        repo.load_persisted();
        repo
    }

    fn load_persisted(&mut self) {
        let Some(ref dir) = self.data_dir else { return };
        let path = heki_path(dir, &self.aggregate_type);
        let records = heki::read(&path).unwrap_or_default();
        for (_, rec) in &records {
            let id = rec.get("id")
                .and_then(|v| v.as_str())
                .unwrap_or("1")
                .to_string();
            if let Ok(n) = id.parse::<u64>() {
                if n >= self.next_id { self.next_id = n + 1; }
            }
            let mut state = AggregateState::new(&id);
            for (key, val) in rec {
                if key != "id" && key != "created_at" && key != "updated_at" {
                    state.set(key, from_json(val));
                }
            }
            self.store.insert(id, state);
        }
        if !self.store.is_empty() {
            eprintln!("  loaded {} {} records from disk",
                self.store.len(), self.aggregate_type);
        }
    }

    /// Resolve the id for a command dispatch.
    ///
    ///   identified_by + attr present → use attr value (explicit)
    ///   identified_by + attr absent + exactly 1 record → use existing id
    ///     (singleton fallback: loop/policy caller didn't pass the id but
    ///      the record already exists; use it rather than counter-minting a
    ///      second record each tick. Mirrors inject_refs logic in mod.rs.)
    ///   identified_by + attr absent + 0 or >1 records → counter-mint
    ///   identified_by absent → counter-mint
    pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        if let Some(ref key) = self.identified_by {
            if let Some(Value::Str(s)) = attrs.get(key) {
                return s.clone();
            }
            // Singleton fallback: no id attr but exactly one existing record.
            if self.store.len() == 1 {
                if let Some(existing) = self.store.values().next() {
                    return existing.id.clone();
                }
            }
        }
        let id = self.next_id;
        self.next_id += 1;
        id.to_string()
    }

    pub fn save(&mut self, state: AggregateState) {
        self.store.insert(state.id.clone(), state);
        if let Some(ref dir) = self.data_dir {
            let path = heki_path(dir, &self.aggregate_type);
            let mut heki_store = heki::Store::new();
            for (id, s) in &self.store {
                let mut rec = heki::Record::new();
                rec.insert("id".into(), serde_json::Value::String(id.clone()));
                for (key, val) in &s.fields {
                    rec.insert(key.clone(), to_json(val));
                }
                heki_store.insert(id.clone(), rec);
            }
            let _ = heki::write(&path, &heki_store);
        }
    }

    /// Remove a record from the in-memory store and persist the
    /// updated set back to heki. The companion to `save` for the
    /// `then_delete` mutation primitive ; only retire-style commands
    /// reach this path.
    pub fn delete(&mut self, id: &str) {
        self.store.remove(id);
        if let Some(ref dir) = self.data_dir {
            let path = heki_path(dir, &self.aggregate_type);
            let _ = heki::delete(&path, id);
        }
    }

    pub fn find(&self, id: &str) -> Option<&AggregateState> {
        self.store.get(id)
    }

    pub fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.store.get_mut(id)
    }

    pub fn all(&self) -> Vec<&AggregateState> {
        self.store.values().collect()
    }

    pub fn count(&self) -> usize {
        self.store.len()
    }
}

/// Heartbeat → {dir}/heartbeat.heki
fn heki_path(dir: &str, aggregate_type: &str) -> String {
    let mut snake = String::new();
    for (i, c) in aggregate_type.chars().enumerate() {
        if c.is_uppercase() && i > 0 { snake.push('_'); }
        snake.push(c.to_lowercase().next().unwrap_or(c));
    }
    format!("{}/{}.heki", dir, snake)
}

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
