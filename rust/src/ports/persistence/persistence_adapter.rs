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
