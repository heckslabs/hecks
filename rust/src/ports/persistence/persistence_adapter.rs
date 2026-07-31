use super::AggregateState;
use super::Value;
use crate::heki;
use crate::ir;
use std::collections::HashMap;

#[derive(Clone, Debug)]
pub struct ReplicationEntry {
    pub operation: String,
    pub id: String,
    pub state: Option<AggregateState>,
    pub mirrors: Vec<String>,
}

pub trait PersistenceAdapter: Send {
    fn find(&self, id: &str) -> Option<&AggregateState>;

    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState>;

    fn all(&self) -> Vec<&AggregateState>;

    fn count(&self) -> usize;

    fn next_id_value(&self) -> u64;

    fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String;

    fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) -> Result<(), String>;

    fn save_with_mirrors(
        &mut self,
        state: AggregateState,
        _mirrors: Vec<String>,
        ctx: heki::WriteContext<'_>,
    ) -> Result<(), String> {
        self.save(state, ctx)
    }

    fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) -> Result<(), String>;

    fn delete_with_mirrors(
        &mut self,
        id: &str,
        _mirrors: Vec<String>,
        ctx: heki::WriteContext<'_>,
    ) -> Result<(), String> {
        self.delete(id, ctx)
    }

    fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> {
        Ok(vec![])
    }

    /// CANDIDATES, NEVER FINAL ROWS.
    ///
    /// `Some(rows)` promises `rows` is a SUPERSET of every stored row satisfying
    /// `wheres` — formally, `matches(r, wheres)` implies `r` is in `rows`. The
    /// caller MUST still apply the whole predicate. `Some(vec![])` therefore
    /// means "provably nothing matches", which is why a caller must not treat an
    /// empty answer as a failure to narrow.
    ///
    /// `None` means "I cannot narrow ; use `all()`". Semantically the same as
    /// `Some(all())`, kept so an adapter need not clone its whole store.
    ///
    /// A SUPERSET AND NOT AN ANSWER, because narrowing is partial by nature: the
    /// SQLite builder skips an unknown column, `Ne`, `Contains`, an empty target
    /// and any comparison it cannot express. Were these final rows, each of those
    /// would be a silent wrong answer, and SQL would have to reproduce every
    /// comparator the dispatcher applies — a second implementation of the
    /// language's own semantics, which is the duplication `bin/undeclared` exists
    /// to find. Under this contract the caller's answer is unchanged by whatever
    /// the adapter can or cannot push, and the whole risk collapses to one
    /// property: NEVER UNDER-RETURN.
    fn query(
        &self,
        wheres: &[ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>>;

    fn seed_record(&mut self, state: AggregateState);

    fn set_next_id(&mut self, value: u64);
}

use crate::ir::Aggregate;
use std::sync::{Mutex, OnceLock};

pub struct PersistenceSpec {
    pub aggregate: Aggregate,
    pub options: HashMap<String, String>,
}

impl PersistenceSpec {
    pub fn option(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(|s| s.as_str())
    }
}

pub type AdapterFactory = fn(&PersistenceSpec) -> Result<Box<dyn PersistenceAdapter>, String>;

static REGISTRY: OnceLock<Mutex<HashMap<String, AdapterFactory>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, AdapterFactory>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn register_persistence_adapter(token: &str, factory: AdapterFactory) {
    registry()
        .lock()
        .expect("persistence adapter registry poisoned")
        .insert(token.to_string(), factory);
}

pub fn persistence_adapter_factory(token: &str) -> Option<AdapterFactory> {
    registry()
        .lock()
        .expect("persistence adapter registry poisoned")
        .get(token)
        .copied()
}
