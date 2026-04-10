//! Repository — in-memory aggregate storage
//!
//! Stores AggregateState instances by ID. The simplest
//! possible persistence — a HashMap. SQL adapters come later.
//!
//! Usage:
//!   let mut repo = Repository::new();
//!   repo.save(state);
//!   let found = repo.find("pizza_1");

use super::AggregateState;
use std::collections::HashMap;

pub struct Repository {
    store: HashMap<String, AggregateState>,
    next_id: u64,
}

impl Repository {
    pub fn new() -> Self {
        Repository {
            store: HashMap::new(),
            next_id: 1,
        }
    }

    pub fn next_id(&mut self) -> String {
        let id = self.next_id;
        self.next_id += 1;
        id.to_string()
    }

    pub fn save(&mut self, state: AggregateState) {
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
