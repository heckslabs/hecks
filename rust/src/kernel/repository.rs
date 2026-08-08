// Generic over the record type — one impl (InMemoryRepository<T>) serves
// every generated aggregate, nothing domain-specific here.
//
// `find` -> `None` for an id never stored, `save` upserts by id. The
// persistence contract itself — which methods a real adapter must answer,
// which are delegated without a presence check, which are optional
// passthroughs, and that `delete`'s return value is explicitly not part of
// the contract — is documented in full in docs/guides/writing-an-adapter.md;
// this trait is a Rust-shaped minimal reading of that same contract
// (`find`/`save`/`all`/`count`), not a second, undocumented one.

use std::collections::BTreeMap;

pub trait Repository<T: Clone> {
    fn find(&self, id: &str) -> Option<T>;
    fn save(&mut self, id: &str, record: T);
    fn all(&self) -> Vec<T>;
    fn count(&self) -> usize;
}

#[derive(Default)]
pub struct InMemoryRepository<T: Clone> {
    records: BTreeMap<String, T>,
}

impl<T: Clone> InMemoryRepository<T> {
    pub fn new() -> Self {
        Self { records: BTreeMap::new() }
    }
}

impl<T: Clone> Repository<T> for InMemoryRepository<T> {
    fn find(&self, id: &str) -> Option<T> {
        self.records.get(id).cloned()
    }

    fn save(&mut self, id: &str, record: T) {
        self.records.insert(id.to_string(), record);
    }

    fn all(&self) -> Vec<T> {
        self.records.values().cloned().collect()
    }

    fn count(&self) -> usize {
        self.records.len()
    }
}
