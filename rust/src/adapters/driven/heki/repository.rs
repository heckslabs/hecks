//! HekiRepository — the append-log store as a persistence PORT.
//!
//! The twin of lib/hecksagain/adapters/driven/heki/heki.rb, and the second
//! adapter this runtime can bind. Until it existed the composition root asked
//! `if persistence.adapter == "Sqlite"` — a name check standing exactly where
//! the port abstraction was supposed to remove one, invisible while there was
//! only one name to check for.
//!
//! THE WHOLE STORE LIVES IN MEMORY, by trait contract rather than choice : the
//! port returns BORROWS into the adapter's own storage (`find(&self) ->
//! Option<&AggregateState>`), so an adapter cannot answer from a file it re-reads
//! per lookup. Heki suits that shape better than most — a .heki file IS the whole
//! store, one compressed map, so it is read once at bind and rewritten whole on
//! each save. That is the honest cost of the format, not a caching trick :
//! decompressing an aggregate to answer one find would be worse.
//!
//! One store per aggregate, named by the same snake_case rule Sqlite names a
//! table with, so the two adapters agree about what a thing is called.

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
    /// Bind a store, reading whatever is already on disk.
    ///
    /// An ABSENT file is an empty store — nobody has written yet. A DAMAGED one
    /// is an error, because answering "no records" for a corrupt file is how a
    /// runtime silently starts over on data it should have refused to lose.
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
            // value_bridge is the one place JSON and the runtime Value meet.
            // Converting by hand here would be a second author for that mapping.
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

    /// The whole store, rewritten. A heki file is one compressed map, so there
    /// is no such thing as writing one record into it.
    fn flush(&self) {
        let records: heki::Store = self
            .store
            .iter()
            .map(|(id, state)| (id.clone(), value_bridge::from_state(state).into_iter().collect()))
            .collect();

        let _ = heki::write(&self.path, &records, heki::WriteContext::OutOfBand { reason: "persist" });
    }
}

// The rule that turns an aggregate into a file name is the same rule that
// turns it into a table name — so it is ONE function, `crate::naming::snake`,
// and not a private copy here. The copy that used to live here said it existed
// "so Sqlite and Heki agree about what a thing is called", while quietly
// disagreeing with both the parser and Ruby about acronyms.

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

    /// NO PUSHDOWN. Sqlite can prefilter in the connection, injection-safe and
    /// indexed ; a heki store is one decompressed map with no index to push a
    /// clause into, so filtering here would be the caller's own loop wearing an
    /// adapter's name.
    ///
    /// `None` means the runtime keeps its `all()` + oracle path, and the oracle
    /// re-applies every clause regardless — so declining costs correctness
    /// nothing. A pushdown can only ever NARROW ; parity holds by construction.
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
