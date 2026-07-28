
use super::heki;
use crate::runtime::{value_bridge, AggregateState, PersistenceAdapter, Value};
use std::collections::HashMap;

pub struct HekiRepository {
    path: String,
    identified_by: Option<String>,
    store: HashMap<String, AggregateState>,
    next_id: u64,
}

impl HekiRepository {
    pub fn new(
        aggregate: &str,
        dir: &str,
        identified_by: Option<String>,
    ) -> Result<Self, String> {
        let path = format!("{}/{}.heki", dir.trim_end_matches('/'), crate::naming::snake(aggregate));

        if let Some(parent) = std::path::Path::new(&path).parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("cannot create {:?}: {}", parent, e))?;
        }

        let raw = heki::read(&path)?;
        let mut store = HashMap::new();
        let mut next_id = 1u64;

        for (id, record) in raw {
            let fields: serde_json::Map<String, serde_json::Value> = record.into_iter().collect();
            if let Ok(n) = id.parse::<u64>() {
                if n >= next_id {
                    next_id = n + 1;
                }
            }
            store.insert(id.clone(), value_bridge::to_state(&id, &fields));
        }

        Ok(Self { path, identified_by, store, next_id })
    }

    fn flush(&self) {
        let records: heki::Store = self
            .store
            .iter()
            .map(|(id, state)| (id.clone(), value_bridge::from_state(state).into_iter().collect()))
            .collect();

        let _ = heki::write(&self.path, &records, heki::WriteContext::OutOfBand { reason: "persist" });
    }
}


impl PersistenceAdapter for HekiRepository {
    fn find(&self, id: &str) -> Option<&AggregateState> {
        self.store.get(id)
    }

    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.store.get_mut(id)
    }

    fn all(&self) -> Vec<&AggregateState> {
        self.store.values().collect()
    }

    fn count(&self) -> usize {
        self.store.len()
    }

    fn next_id_value(&self) -> u64 {
        self.next_id
    }

    fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        if let Some(ref key) = self.identified_by {
            if let Some(Value::Str(supplied)) = attrs.get(key) {
                return supplied.clone();
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

    fn save(&mut self, state: AggregateState, _ctx: heki::WriteContext<'_>) {
        self.store.insert(state.id.clone(), state);
        self.flush();
    }

    fn delete(&mut self, id: &str, _ctx: heki::WriteContext<'_>) {
        self.store.remove(id);
        self.flush();
    }

    fn query(
        &self,
        _wheres: &[crate::ir::WhereClause],
        _attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>> {
        None
    }

    fn seed_record(&mut self, state: AggregateState) {
        if let Ok(n) = state.id.parse::<u64>() {
            if n >= self.next_id {
                self.next_id = n + 1;
            }
        }
        self.store.insert(state.id.clone(), state);
    }

    fn set_next_id(&mut self, value: u64) {
        if value > self.next_id {
            self.next_id = value;
        }
    }
}
