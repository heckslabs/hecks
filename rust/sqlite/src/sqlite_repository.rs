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

use crate::sqlite_mapping::{quote_ident, value_from_sql, value_to_sql};
use storehouse::runtime::AggregateState;
use storehouse::runtime::Value;
use storehouse::heki;
use rusqlite::Connection;
use std::collections::HashMap;

pub struct SqliteRepository {
    // pub(super) so the where()-pushdown surface (sqlite_query.rs, a sibling
    // module) can read the connection + typed columns + cache it filters over.
    pub(super) conn: Connection,
    pub(super) table: String,
    /// Scalar column names in declared order (attribute names). The
    /// `id`, `created_at`, `updated_at` columns are handled separately.
    pub(super) columns: Vec<String>,
    /// Subset of `columns` whose SQL type is INTEGER — the columns a numeric
    /// range predicate may push as `CAST(col AS INTEGER) OP ?` (exact vs the
    /// oracle, since their values are i64). REAL / text columns are excluded : the
    /// oracle compares them lexically (a float string doesn't parse i64), which
    /// CAST-as-integer would not match.
    pub(super) numeric_columns: Vec<String>,
    pub(super) store: HashMap<String, AggregateState>,
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
        let table = storehouse::naming::snake(aggregate_type);
        let col_names: Vec<String> = columns.iter().map(|(n, _)| n.clone()).collect();
        let numeric_columns: Vec<String> = columns.iter()
            .filter(|(_, ty)| ty.to_uppercase().starts_with("INTEGER"))
            .map(|(n, _)| n.clone())
            .collect();
        Self::create_table(&conn, &table, &columns)?;
        let mut repo = SqliteRepository {
            conn,
            table,
            columns: col_names,
            numeric_columns,
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
            defs.push(format!("{} {ty}", quote_ident(name)));
        }
        defs.push("created_at DATETIME".to_string());
        defs.push("updated_at DATETIME".to_string());
        let ddl = format!(
            "CREATE TABLE IF NOT EXISTS {} (\n  {}\n)",
            quote_ident(table),
            defs.join(",\n  "),
        );
        conn.execute_batch(&ddl)?;
        Ok(())
    }

    fn load_persisted(&mut self) {
        let quoted_cols: Vec<String> = self.columns.iter().map(|c| quote_ident(c)).collect();
        let select = format!(
            "SELECT id, {} FROM {}",
            quoted_cols.join(", "),
            quote_ident(&self.table),
        );
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
        let quoted_cols: Vec<String> = col_list.iter().map(|c| quote_ident(c)).collect();
        let upsert = format!(
            "INSERT INTO {t} ({cols}) VALUES ({ph}) ON CONFLICT(id) DO UPDATE SET {set}, updated_at = CURRENT_TIMESTAMP",
            t = quote_ident(&self.table),
            cols = quoted_cols.join(", "),
            ph = placeholders.join(", "),
            set = self.columns.iter().map(|c| {
                let q = quote_ident(c);
                format!("{q} = excluded.{q}")
            }).collect::<Vec<_>>().join(", "),
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
            &format!("DELETE FROM {} WHERE id = ?1", quote_ident(&self.table)),
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

/// SqliteRepository as the persistence PORT. Thin forwards to the inherent
/// surface — inherent methods win method resolution, so `self.find(..)` calls
/// the concrete impl and never recurses. This is the seam that lets the kernel
/// hold sqlite as `Box<dyn PersistenceAdapter>` and name no concrete engine.
impl storehouse::runtime::PersistenceAdapter for SqliteRepository {
    fn find(&self, id: &str) -> Option<&AggregateState> { self.find(id) }
    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> { self.find_mut(id) }
    fn all(&self) -> Vec<&AggregateState> { self.all() }
    fn count(&self) -> usize { self.count() }
    fn next_id_value(&self) -> u64 { self.next_id_value() }
    fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String { self.id_for_command(attrs) }
    fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) { self.save(state, ctx) }
    fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) { self.delete(id, ctx) }
    fn query(
        &self,
        wheres: &[storehouse::ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>> {
        Some(self.query(wheres, attrs))
    }
    fn seed_record(&mut self, state: AggregateState) { self.seed_record(state) }
    fn set_next_id(&mut self, value: u64) { self.set_next_id(value) }
}

/// Build a SqliteRepository as a boxed `PersistenceAdapter` from the generic
/// `PersistenceSpec`. The sqlite-specific column TYPING lives HERE — it is
/// sqlite's business, not the kernel's : one column per scalar attribute via
/// `sqlite_mapping::sql_type` (excluding the auto-managed id/created_at/
/// updated_at), a TEXT column for the lifecycle state field, and expression
/// indexes for the columns the declared queries filter / sort on. EAGER +
/// FALLIBLE (i735 defect 2) : open + CREATE TABLE + row-load happen now, so a
/// failed build refuses the aggregate at boot rather than deferring a Result
/// the infallible read surface can't fail through.
pub fn sqlite_factory(
    spec: &storehouse::runtime::PersistenceSpec,
) -> Result<Box<dyn storehouse::runtime::PersistenceAdapter>, String> {
    let agg = &spec.aggregate;
    let db_path = spec
        .option("db")
        .ok_or_else(|| format!("sqlite adapter for `{}` is missing its `db:` option", agg.name))?;
    let mut columns: Vec<(String, String)> = agg
        .attributes
        .iter()
        .filter(|a| !a.list && !matches!(a.name.as_str(), "id" | "created_at" | "updated_at"))
        .map(|a| (a.name.clone(), crate::sqlite_mapping::sql_type(&a.attr_type).to_string()))
        .collect();
    if let Some(lc) = &agg.lifecycle {
        // The lifecycle state field is usually ALSO a declared attribute
        // (the lifecycle is declared ON an attribute — Order's `status`),
        // which already added the column above. Only add it when no
        // attribute of that name exists, else the DDL carries a duplicate
        // column (`status TEXT, status TEXT`) and CREATE TABLE fails.
        if !columns.iter().any(|(n, _)| n == &lc.field) {
            columns.push((lc.field.clone(), "TEXT".to_string()));
        }
    }
    let mut indexed_columns: Vec<String> = Vec::new();
    for q in &agg.queries {
        for w in &q.wheres {
            if !indexed_columns.contains(&w.field) {
                indexed_columns.push(w.field.clone());
            }
        }
        if let Some(ob) = &q.order_by {
            if !indexed_columns.contains(&ob.field) {
                indexed_columns.push(ob.field.clone());
            }
        }
    }
    let repo = SqliteRepository::new(&agg.name, db_path, agg.identified_by.clone(), columns)
        .map_err(|e| format!("open/CREATE TABLE failed for db `{db_path}`: {e}"))?;
    repo.ensure_indexes(&indexed_columns);
    Ok(Box::new(repo))
}

/// Register the sqlite backend under the `sqlite` hexagon token. Idempotent.
/// TEMPORARY home (Phase 2a) : the crate split moves this into the
/// storehouse-sqlite crate, called by the cli composition root before boot.
pub fn register() {
    storehouse::runtime::register_persistence_adapter("sqlite", sqlite_factory);
}
