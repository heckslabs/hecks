//! SqliteRepository — typed-column SQL persistence backend
//!
//! The SQL mirror of `Repository` (the heki backend). One table per
//! aggregate, ONE COLUMN PER ATTRIBUTE — types derived from the
//! bluebook IR, never a JSON blob. Identity: aggregates carry no
//! `identified_by` by convention, so the runtime mints an id and this
//! table stores it under a `TEXT PRIMARY KEY` `id` column.
//!
//! Parity target — Ruby's Sequel layer (`ruby/hecks_persist/`):
//!   - DDL + type map  ← SqlMigrationGenerator / SqlBoot.sequel_type
//!   - find/all/save/delete/count  ← SqlAdapterGenerator
//!   - String→VARCHAR(255), Integer→INTEGER, Float→REAL,
//!     Boolean→BOOLEAN, else→TEXT  ← sql_type (verbatim)
//!   - created_at / updated_at DATETIME columns  ← SqlBoot.create_aggregate_table
//!
//! The surface mirrors `Repository` so `LazyRepository` can multiplex
//! the two backends behind one forwarding API. `save`/`delete` accept a
//! `heki::WriteContext` for signature parity with the heki backend and
//! ignore it — SQL writes are their own durability story.
//!
//! Eager-load on construction (like the heki Repository): every row is
//! read into an in-memory `HashMap<String, AggregateState>` so the
//! `&AggregateState`-returning read methods (`find`/`all`) work without
//! an owned-row dance. Writes go through both the cache and the table.
//!
//! Usage:
//!   let cols = vec![("title".into(), "VARCHAR(255)".into())];
//!   let repo = SqliteRepository::new("BlogEntry", "/tmp/app.db", None, cols)?; // fallible

use super::sqlite_mapping::{value_from_sql, value_to_sql};
use super::AggregateState;
use super::Value;
use crate::heki;
use rusqlite::Connection;
use std::collections::HashMap;

pub struct SqliteRepository {
    conn: Connection,
    table: String,
    /// Scalar column names in declared order (attribute names). The
    /// `id`, `created_at`, `updated_at` columns are handled separately.
    columns: Vec<String>,
    store: HashMap<String, AggregateState>,
    next_id: u64,
    identified_by: Option<String>,
}

impl SqliteRepository {
    /// Open (or create) the db at `db_path`, ensure the aggregate's
    /// table exists with typed columns derived from the IR attribute
    /// list, then eager-load existing rows into the cache.
    ///
    /// `columns` is `(attribute_name, sql_type)` pairs — the caller
    /// (runtime boot) maps each scalar attribute's `attr_type` through
    /// `sql_type` to get the SQL type, mirroring Ruby's SqlBoot.
    /// i735 defect 2 — FALLIBLE : open + CREATE TABLE return `Err`
    /// instead of panicking. A SQL-incompatible column (reserved word,
    /// `id` collision) or an unopenable db no longer takes down the bus ;
    /// the runtime refuses that aggregate's persistence LOUDLY (see
    /// `Runtime::apply_sqlite_persistence`) rather than panicking or
    /// silently swapping to heki.
    pub fn new(
        aggregate_type: &str,
        db_path: &str,
        identified_by: Option<String>,
        columns: Vec<(String, String)>,
    ) -> Result<Self, rusqlite::Error> {
        if let Some(parent) = std::path::Path::new(db_path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(db_path)?;
        let table = crate::util::snake_case(aggregate_type);
        let col_names: Vec<String> = columns.iter().map(|(n, _)| n.clone()).collect();
        Self::create_table(&conn, &table, &columns)?;
        let mut repo = SqliteRepository {
            conn,
            table,
            columns: col_names,
            store: HashMap::new(),
            next_id: 1,
            identified_by,
        };
        repo.load_persisted();
        Ok(repo)
    }

    fn create_table(
        conn: &Connection,
        table: &str,
        columns: &[(String, String)],
    ) -> Result<(), rusqlite::Error> {
        let mut defs = vec!["id TEXT PRIMARY KEY".to_string()];
        for (name, ty) in columns {
            defs.push(format!("{name} {ty}"));
        }
        defs.push("created_at DATETIME".to_string());
        defs.push("updated_at DATETIME".to_string());
        let ddl = format!("CREATE TABLE IF NOT EXISTS {table} (\n  {}\n)", defs.join(",\n  "));
        conn.execute_batch(&ddl)?;
        Ok(())
    }

    fn load_persisted(&mut self) {
        let select = format!("SELECT id, {} FROM {}", self.columns.join(", "), self.table);
        let mut stmt = match self.conn.prepare(&select) {
            Ok(s) => s,
            Err(_) => return,
        };
        let cols = self.columns.clone();
        let rows = stmt.query_map([], |row| {
            let id: String = row.get(0)?;
            let mut state = AggregateState::new(&id);
            for (i, name) in cols.iter().enumerate() {
                state.set(name, value_from_sql(row, i + 1));
            }
            Ok(state)
        });
        if let Ok(mapped) = rows {
            for state in mapped.flatten() {
                if let Ok(n) = state.id.parse::<u64>() {
                    if n >= self.next_id { self.next_id = n + 1; }
                }
                self.store.insert(state.id.clone(), state);
            }
        }
    }

    pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        if let Some(ref key) = self.identified_by {
            if let Some(Value::Str(s)) = attrs.get(key) {
                return s.clone();
            }
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

    pub fn save(&mut self, state: AggregateState, _ctx: heki::WriteContext<'_>) {
        let mut col_list = vec!["id".to_string()];
        col_list.extend(self.columns.iter().cloned());
        let placeholders: Vec<String> =
            (1..=col_list.len()).map(|i| format!("?{i}")).collect();
        let upsert = format!(
            "INSERT INTO {t} ({cols}) VALUES ({ph}) ON CONFLICT(id) DO UPDATE SET {set}, updated_at = CURRENT_TIMESTAMP",
            t = self.table,
            cols = col_list.join(", "),
            ph = placeholders.join(", "),
            set = self.columns.iter().map(|c| format!("{c} = excluded.{c}")).collect::<Vec<_>>().join(", "),
        );
        let mut params: Vec<rusqlite::types::Value> = vec![state.id.clone().into()];
        for c in &self.columns {
            params.push(value_to_sql(state.get(c)));
        }
        let refs: Vec<&dyn rusqlite::ToSql> =
            params.iter().map(|p| p as &dyn rusqlite::ToSql).collect();
        let _ = self.conn.execute(&upsert, refs.as_slice());
        self.store.insert(state.id.clone(), state);
    }

    pub fn delete(&mut self, id: &str, _ctx: heki::WriteContext<'_>) {
        self.store.remove(id);
        let _ = self.conn.execute(
            &format!("DELETE FROM {} WHERE id = ?1", self.table),
            [id],
        );
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

    pub fn seed_record(&mut self, state: AggregateState) {
        if let Ok(n) = state.id.parse::<u64>() {
            if n >= self.next_id { self.next_id = n + 1; }
        }
        self.store.insert(state.id.clone(), state);
    }

    pub fn next_id_value(&self) -> u64 {
        self.next_id
    }

    pub fn set_next_id(&mut self, value: u64) {
        if value > self.next_id { self.next_id = value; }
    }
}
