//! Repository — in-memory aggregate storage with disk persistence
//!
//! Stores AggregateState instances by ID. On every save, also
//! writes to a JSON file so state survives server restarts.
//!
//! Usage:
//!   let mut repo = Repository::new("Brand", Some("./data".into()));
//!   repo.save(state);
//!   let found = repo.find("pizza_1");

use super::AggregateState;
use super::persistence;
use std::collections::HashMap;

pub struct Repository {
    store: HashMap<String, AggregateState>,
    next_id: u64,
    aggregate_type: String,
    data_dir: Option<String>,
}

impl Repository {
    pub fn new(aggregate_type: &str, data_dir: Option<String>) -> Self {
        let mut repo = Repository {
            store: HashMap::new(),
            next_id: 1,
            aggregate_type: aggregate_type.to_string(),
            data_dir,
        };
        repo.load_persisted();
        repo
    }

    fn load_persisted(&mut self) {
        if let Some(ref dir) = self.data_dir {
            let records = persistence::load_from_disk(dir, &self.aggregate_type);
            for state in records {
                if let Ok(n) = state.id.parse::<u64>() {
                    if n >= self.next_id {
                        self.next_id = n + 1;
                    }
                }
                self.store.insert(state.id.clone(), state);
            }
            if !self.store.is_empty() {
                eprintln!(
                    "  loaded {} {} records from disk",
                    self.store.len(),
                    self.aggregate_type
                );
            }
        }
    }

    pub fn next_id(&mut self) -> String {
        let id = self.next_id;
        self.next_id += 1;
        id.to_string()
    }

    pub fn save(&mut self, state: AggregateState) {
        if let Some(ref dir) = self.data_dir {
            persistence::save_to_disk(dir, &self.aggregate_type, &state);
        }
        self.store.insert(state.id.clone(), state);
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
