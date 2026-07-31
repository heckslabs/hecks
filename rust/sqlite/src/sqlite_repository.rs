use crate::sqlite_mapping::{quote_ident, value_from_sql, value_to_sql};
use rusqlite::Connection;
use serde_json;
use std::collections::HashMap;
use storehouse::heki;
use storehouse::runtime::AggregateState;
use storehouse::runtime::Value;
use storehouse::value_bridge;
use storehouse::ports::persistence::ReplicationEntry;

pub struct SqliteRepository {
    pub(super) conn: Connection,
    pub(super) table: String,
    pub(super) columns: Vec<String>,
    pub(super) numeric_columns: Vec<String>,
    /// Column -> the field inside its value object that carries the number.
    /// A third category the two Vecs above cannot express: not "the column is
    /// numeric" (it is TEXT, holding JSON) but "the number is at this path".
    pub(super) numeric_paths: HashMap<String, String>,
    float_columns: Vec<String>,
    pub(super) store: HashMap<String, AggregateState>,
    next_id: u64,
    identified_by: Option<String>,
}

impl SqliteRepository {
    /// `numeric_paths` is REQUIRED rather than a setter on purpose: a repository
    /// without it silently under-answers every comparison on a value-object
    /// column, which is the exact failure this parameter exists to end. Making
    /// one is then impossible rather than merely discouraged.
    pub fn new(
        aggregate_type: &str,
        db_path: &str,
        identified_by: Option<String>,
        columns: Vec<(String, String)>,
        numeric_paths: HashMap<String, String>,
    ) -> Result<Self, rusqlite::Error> {
        if let Some(parent) = std::path::Path::new(db_path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(db_path)?;
        let table = storehouse::naming::snake(aggregate_type);
        let col_names: Vec<String> = columns.iter().map(|(n, _)| n.clone()).collect();
        let numeric_columns: Vec<String> = columns
            .iter()
            .filter(|(_, ty)| ty.to_uppercase().starts_with("INTEGER"))
            .map(|(n, _)| n.clone())
            .collect();
        let float_columns: Vec<String> = columns
            .iter()
            .filter(|(_, ty)| ty.to_uppercase().starts_with("REAL"))
            .map(|(n, _)| n.clone())
            .collect();
        Self::create_table(&conn, &table, &columns)?;
        Self::create_entry_table(&conn, &table)?;
        Self::ensure_entry_columns(&conn, &table)?;
        let mut repo = SqliteRepository {
            conn,
            table,
            columns: col_names,
            numeric_columns,
            numeric_paths,
            float_columns,
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

    fn create_entry_table(conn: &Connection, table: &str) -> Result<(), rusqlite::Error> {
        conn.execute_batch(&format!(
            "CREATE TABLE IF NOT EXISTS {} (sequence INTEGER PRIMARY KEY AUTOINCREMENT, aggregate_id TEXT NOT NULL, operation TEXT NOT NULL DEFAULT 'save', state TEXT, mirrors TEXT)",
            quote_ident(&format!("{}_entries", table)),
        ))
    }

    fn ensure_entry_columns(conn: &Connection, table: &str) -> Result<(), rusqlite::Error> {
        let entry_table = quote_ident(&format!("{}_entries", table));
        let mut statement = conn.prepare(&format!("PRAGMA table_info({entry_table})"))?;
        let columns: Vec<String> = statement.query_map([], |row| row.get(1))?
            .collect::<Result<_, _>>()?;
        if !columns.iter().any(|column| column == "operation") {
            conn.execute(&format!("ALTER TABLE {entry_table} ADD COLUMN operation TEXT NOT NULL DEFAULT 'save'"), [])?;
        }
        if !columns.iter().any(|column| column == "mirrors") {
            conn.execute(&format!("ALTER TABLE {entry_table} ADD COLUMN mirrors TEXT"), [])?;
        }
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
                    if n >= self.next_id {
                        self.next_id = n + 1;
                    }
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

    pub fn save_with_mirrors(&mut self, mut state: AggregateState, mirrors: Vec<String>, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        // The append-only entry records the command's submitted state. The
        // current projection below then applies SQLite's declared column type.
        let state_json =
            serde_json::to_string(&value_bridge::from_state(&state)).unwrap_or_default();
        for column in &self.float_columns {
            if let Value::Int(value) = state.get(column) {
                state.set(column, Value::Float(*value as f64));
            }
        }
        let entry_table = quote_ident(&format!("{}_entries", self.table));
        self.conn.execute(
            &format!(
                "INSERT INTO {} (aggregate_id, operation, state, mirrors) VALUES (?1, 'save', ?2, ?3)",
                entry_table
            ),
            rusqlite::params![&state.id, &state_json, serde_json::to_string(&mirrors).unwrap_or_default()],
        ).map_err(|error| format!("cannot append {} history: {error}", self.table))?;
        let mut col_list = vec!["id".to_string()];
        col_list.extend(self.columns.iter().cloned());
        let placeholders: Vec<String> = (1..=col_list.len()).map(|i| format!("?{i}")).collect();
        let quoted_cols: Vec<String> = col_list.iter().map(|c| quote_ident(c)).collect();
        let upsert = format!(
            "INSERT INTO {t} ({cols}) VALUES ({ph}) ON CONFLICT(id) DO UPDATE SET {set}",
            t = quote_ident(&self.table),
            cols = quoted_cols.join(", "),
            ph = placeholders.join(", "),
            set = self
                .columns
                .iter()
                .map(|c| {
                    let q = quote_ident(c);
                    format!("{q} = excluded.{q}")
                })
                .collect::<Vec<_>>()
                .join(", "),
        );
        let mut params: Vec<rusqlite::types::Value> = vec![state.id.clone().into()];
        for c in &self.columns {
            params.push(value_to_sql(state.get(c)));
        }
        let refs: Vec<&dyn rusqlite::ToSql> =
            params.iter().map(|p| p as &dyn rusqlite::ToSql).collect();
        self.conn.execute(&upsert, refs.as_slice())
            .map_err(|error| format!("cannot save {}: {error}", self.table))?;
        self.store.insert(state.id.clone(), state);
        Ok(())
    }

    pub fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save_with_mirrors(state, vec![], ctx)
    }

    pub fn delete_with_mirrors(&mut self, id: &str, mirrors: Vec<String>, _ctx: heki::WriteContext<'_>) -> Result<(), String> {
        let entry_table = quote_ident(&format!("{}_entries", self.table));
        self.conn.execute(
            &format!("INSERT INTO {} (aggregate_id, operation, state, mirrors) VALUES (?1, 'delete', NULL, ?2)", entry_table),
            rusqlite::params![id, serde_json::to_string(&mirrors).unwrap_or_default()],
        ).map_err(|error| format!("cannot append {} history: {error}", self.table))?;
        self.conn.execute(
            &format!("DELETE FROM {} WHERE id = ?1", quote_ident(&self.table)),
            [id],
        ).map_err(|error| format!("cannot delete {}: {error}", self.table))?;
        self.store.remove(id);
        Ok(())
    }

    pub fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete_with_mirrors(id, vec![], ctx)
    }

    pub fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> {
        let entry_table = quote_ident(&format!("{}_entries", self.table));
        let mut statement = self.conn.prepare(&format!("SELECT aggregate_id, operation, state, mirrors FROM {entry_table} ORDER BY sequence"))
            .map_err(|error| format!("cannot read {} history: {error}", self.table))?;
        let rows = statement.query_map([], |row| {
            let operation: String = row.get(1)?;
            let id: String = row.get(0)?;
            let state_json: Option<String> = row.get(2)?;
            let mirrors_json: Option<String> = row.get(3)?;
            let state = state_json.map(|json| {
                let fields: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&json).map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
                Ok::<AggregateState, rusqlite::Error>(value_bridge::to_state(&id, &fields))
            }).transpose()?;
            let mirrors = mirrors_json.map(|json| serde_json::from_str(&json).unwrap_or_default()).unwrap_or_default();
            Ok(ReplicationEntry { operation, id, state, mirrors })
        }).map_err(|error| format!("cannot read {} history: {error}", self.table))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|error| format!("cannot read {} history: {error}", self.table))
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
            if n >= self.next_id {
                self.next_id = n + 1;
            }
        }
        self.store.insert(state.id.clone(), state);
    }

    pub fn next_id_value(&self) -> u64 {
        self.next_id
    }

    pub fn set_next_id(&mut self, value: u64) {
        if value > self.next_id {
            self.next_id = value;
        }
    }
}

impl storehouse::runtime::PersistenceAdapter for SqliteRepository {
    fn find(&self, id: &str) -> Option<&AggregateState> {
        self.find(id)
    }
    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.find_mut(id)
    }
    fn all(&self) -> Vec<&AggregateState> {
        self.all()
    }
    fn count(&self) -> usize {
        self.count()
    }
    fn next_id_value(&self) -> u64 {
        self.next_id_value()
    }
    fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        self.id_for_command(attrs)
    }
    fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save(state, ctx)
    }
    fn save_with_mirrors(&mut self, state: AggregateState, mirrors: Vec<String>, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.save_with_mirrors(state, mirrors, ctx)
    }
    fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete(id, ctx)
    }
    fn delete_with_mirrors(&mut self, id: &str, mirrors: Vec<String>, ctx: heki::WriteContext<'_>) -> Result<(), String> {
        self.delete_with_mirrors(id, mirrors, ctx)
    }
    fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> { self.replication_entries() }
    fn query(
        &self,
        wheres: &[storehouse::ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>> {
        Some(self.query(wheres, attrs))
    }
    fn seed_record(&mut self, state: AggregateState) {
        self.seed_record(state)
    }
    fn set_next_id(&mut self, value: u64) {
        self.set_next_id(value)
    }
}

/// WHERE THE NUMBER LIVES INSIDE EACH VALUE-OBJECT COLUMN.
///
/// A value object is stored as its JSON object, so `balance` holds
/// `{"cents":2500}` and comparing that column against `2500` compares text
/// against an object. Ruby's `query_expression` digs the FIRST Integer/Float
/// member the value object declares — `$.cents` for a Price, `$.amount` for a
/// DailyFee — and only for a NON-LIST attribute (`value_object?`). Same reading
/// here, from the same declaration, so the two adapters cannot drift apart
/// without the bluebook moving under both.
///
/// The list filter is not fussiness: pizzas' `toppings` is `list_of(Topping)`
/// and Topping declares `amount: Integer`, so without it this would dig
/// `$.amount` out of a JSON array.
fn numeric_paths(agg: &storehouse::ir::Aggregate) -> HashMap<String, String> {
    agg.attributes
        .iter()
        .filter(|attribute| !attribute.list)
        .filter_map(|attribute| {
            let shape = agg
                .value_objects
                .iter()
                .find(|held| held.name == attribute.attr_type)?;
            let member = shape
                .attributes
                .iter()
                .find(|held| matches!(held.attr_type.as_str(), "Integer" | "Float"))?;

            // The path is INTERPOLATED into SQL, never bound. A declared name is
            // not user input, but "bound, never interpolated" is the rule this
            // file keeps, and a member name is the one thing here that could
            // qualify it.
            let plain = member
                .name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_');

            plain.then(|| (attribute.name.clone(), member.name.clone()))
        })
        .collect()
}

pub fn sqlite_factory(
    spec: &storehouse::runtime::PersistenceSpec,
) -> Result<Box<dyn storehouse::runtime::PersistenceAdapter>, String> {
    let agg = &spec.aggregate;
    let db_path = spec.option("db").ok_or_else(|| {
        format!(
            "sqlite adapter for `{}` is missing its `db:` option",
            agg.name
        )
    })?;
    let mut columns: Vec<(String, String)> = agg
        .attributes
        .iter()
        .filter(|a| !matches!(a.name.as_str(), "id" | "created_at" | "updated_at"))
        .map(|a| {
            (
                a.name.clone(),
                if a.list { "TEXT".to_string() } else { crate::sqlite_mapping::sql_type(&a.attr_type).to_string() },
            )
        })
        .collect();
    // `reference_to` declares an aggregate attribute in its own right.  Its
    // value is the referenced aggregate head, so persistence uses that
    // attribute's declared name (for example `customer_id`), just as the Ruby
    // adapter does.  Do not synthesize a second `*_id` column: it would never
    // receive the state value and makes a mirrored store diverge on reload.
    for reference in &agg.references {
        let name = reference.name.clone();
        if !columns.iter().any(|(column, _)| column == &name) {
            columns.push((name, "TEXT".to_string()));
        }
    }
    if let Some(lc) = &agg.lifecycle {
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
    let repo = SqliteRepository::new(
        &agg.name,
        db_path,
        agg.identified_by.clone(),
        columns,
        numeric_paths(agg),
    )
    .map_err(|e| format!("open/CREATE TABLE failed for db `{db_path}`: {e}"))?;
    repo.ensure_indexes(&indexed_columns);
    Ok(Box::new(repo))
}

pub fn register() {
    storehouse::runtime::register_persistence_adapter("sqlitepersistence", sqlite_factory);
    storehouse::runtime::register_persistence_adapter("sqlitemirror", sqlite_factory);
}

#[cfg(test)]
mod numeric_path_tests {
    use super::numeric_paths;

    // Anchored to the manifest dir: a workspace member's tests run with the CRATE
    // root as cwd, not the workspace root.
    const PIZZAS: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../examples/pizzas/bluebook/pizzas.bluebook"
    );

    fn pizzas() -> storehouse::ir::Domain {
        let source = std::fs::read_to_string(PIZZAS).expect("read the pizzas bluebook");
        storehouse::parser::parse(&source)
    }

    // READ FROM THE REAL DECLARATION, not a synthetic one — the value this has to
    // get right is the one the corpus actually declares.
    #[test]
    fn a_value_object_column_points_at_its_first_number() {
        let domain = pizzas();
        let pizza = domain
            .aggregates
            .iter()
            .find(|a| a.name == "Pizza")
            .expect("pizzas declares a Pizza");

        let paths = numeric_paths(pizza);

        assert_eq!(paths.get("price_cents"), Some(&"cents".to_string()));
    }

    // A LIST GETS NO PATH. `toppings` is `list_of(Topping)` and Topping declares
    // `amount: Integer`, so without the list filter this would dig `$.amount`
    // out of a JSON ARRAY and quietly match nothing.
    #[test]
    fn a_list_of_value_objects_gets_no_path() {
        let domain = pizzas();
        let pizza = domain
            .aggregates
            .iter()
            .find(|a| a.name == "Pizza")
            .expect("pizzas declares a Pizza");

        assert!(pizza.attributes.iter().any(|a| a.name == "toppings" && a.list));
        assert_eq!(numeric_paths(pizza).get("toppings"), None);
    }

    // A value object with no number at all, and a lifecycle column, get none.
    #[test]
    fn a_column_with_no_number_gets_no_path() {
        let domain = pizzas();
        let pizza = domain
            .aggregates
            .iter()
            .find(|a| a.name == "Pizza")
            .expect("pizzas declares a Pizza");

        let paths = numeric_paths(pizza);
        assert_eq!(paths.get("name"), None, "a Name carries only a String");
    }
}
