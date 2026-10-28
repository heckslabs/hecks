//! The in-memory backend: a journal, snapshot, sagas and dead letters held in process.
//!
//! For local runs and tests only, because nothing here survives a restart. A [`MemoryStore`] is
//! one domain's data. The domain lock is an async mutex taken by [`MemoryUnit`] and held, across
//! the kernel run, until the unit commits, rolls back or is dropped. A unit stages nothing: its
//! writes are applied together under one short write lock at commit, so a commit that fails
//! leaves the committed data as it was.

use super::{Accepted, DeadLetter, State, StoreError};
use crate::store::journal_sql::{storage_name, LineageConfig, Mutation, SagaRow, Snapshot};
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, PoisonError, RwLock};
use tokio::sync::{Mutex, OwnedMutexGuard};

/// One journal row: the ordinal the store assigned and the step it replays.
#[derive(Clone)]
pub(super) struct Row {
    pub(super) ordinal: i64,
    pub(super) step: serde_json::Value,
}

/// A delivery that exhausted its retries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeadLetterRecord {
    pub policy: String,
    pub target_domain: String,
    pub target_verb: String,
    pub payload: serde_json::Value,
    pub error: String,
    pub attempts: i32,
}

/// Everything committed so far.
#[derive(Default)]
pub(super) struct Data {
    pub(super) journal: Vec<Row>,
    pub(super) snapshot: Option<Snapshot>,
    pub(super) sagas: BTreeMap<(String, String), SagaRow>,
    pub(super) dead_letters: Vec<DeadLetterRecord>,
    /// The era-shaped head rows, `(domain, storage name)` to id to state: what the Postgres head
    /// views answer, written by the lineage mutations of each committed step.
    pub(super) heads: BTreeMap<(String, String), BTreeMap<String, serde_json::Value>>,
}

/// Where a commit is made to fail, so a test can assert that nothing became visible.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// Fails after the journal row is staged, before the snapshot is.
    Snapshot,
    /// Fails after the saga writes are staged.
    AfterSagas,
}

struct Shared {
    lock: Arc<Mutex<()>>,
    data: RwLock<Data>,
    fault: StdMutex<Option<Fault>>,
}

/// A domain's journal, snapshot and sagas in memory. Cloning shares the same data and lock.
#[derive(Clone)]
pub struct MemoryStore {
    shared: Arc<Shared>,
}

/// Journal rows as `(ordinal, verb, args)`, the snapshot and the live sagas.
#[cfg(test)]
type Committed = (
    Vec<(i64, String, serde_json::Value)>,
    Option<Snapshot>,
    Vec<SagaRow>,
);

type Registry = StdMutex<HashMap<(String, String), MemoryStore>>;

impl MemoryStore {
    /// An empty store of its own.
    #[must_use]
    pub fn new() -> Self {
        Self {
            shared: Arc::new(Shared {
                lock: Arc::new(Mutex::new(())),
                data: RwLock::new(Data::default()),
                fault: StdMutex::new(None),
            }),
        }
    }

    /// The process-wide store for `domain` in `schema`, created empty on first use, so two
    /// tenants of one process never share a journal.
    #[must_use]
    pub fn open(domain: &str, schema: Option<&str>) -> Self {
        static STORES: OnceLock<Registry> = OnceLock::new();
        let key = (domain.to_string(), schema.unwrap_or_default().to_string());
        let mut stores = STORES
            .get_or_init(Registry::default)
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        stores.entry(key).or_default().clone()
    }

    /// Takes the domain lock and opens the scope a dispatch writes in.
    pub(super) async fn begin(&self) -> MemoryUnit {
        let guard = Arc::clone(&self.shared.lock).lock_owned().await;
        MemoryUnit {
            store: self.clone(),
            _guard: guard,
        }
    }

    /// The last committed snapshot and the steps after it, read without the domain lock.
    pub(super) fn read_state(&self) -> State {
        let data = self.read();
        let steps = steps_after(&data, data.snapshot.as_ref().map(|s| s.ordinal));
        State {
            snapshot: data.snapshot.clone(),
            steps,
            sagas: Vec::new(),
        }
    }

    /// The head row `id` of one aggregate's head, or `None`.
    pub(super) fn head_by_id(
        &self,
        domain: &str,
        storage_name: &str,
        id: &str,
    ) -> Option<serde_json::Value> {
        let data = self.read();
        let key = (domain.to_string(), storage_name.to_string());
        data.heads.get(&key).and_then(|rows| rows.get(id)).cloned()
    }

    /// Every head row of one aggregate, by id.
    pub(super) fn head_all(
        &self,
        domain: &str,
        storage_name: &str,
    ) -> Vec<(String, serde_json::Value)> {
        let data = self.read();
        let key = (domain.to_string(), storage_name.to_string());
        data.heads
            .get(&key)
            .map(|rows| {
                rows.iter()
                    .map(|(id, state)| (id.clone(), state.clone()))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Every head state of the first of `domains` that keeps heads for `storage_name`, by id.
    pub(super) fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> Vec<serde_json::Value> {
        let data = self.read();
        domains
            .iter()
            .find_map(|domain| {
                data.heads
                    .get(&(domain.to_string(), storage_name.to_string()))
            })
            .map(|rows| rows.values().cloned().collect())
            .unwrap_or_default()
    }

    /// The head row whose `matches` fields all hold, from the first of `domains` that has a head
    /// for `storage_name`; that head decides, as the first existing Postgres view does.
    pub(super) fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Option<serde_json::Value> {
        let data = self.read();
        let rows = domains.iter().find_map(|domain| {
            data.heads
                .get(&(domain.to_string(), storage_name.to_string()))
        })?;
        rows.values()
            .find(|state| {
                matches
                    .iter()
                    .all(|(field, value)| state[*field]["value"].as_str() == Some(*value))
            })
            .cloned()
    }

    /// Writes head rows as one step: refused whole when the domain has no era or an operation is
    /// not `save`, as the Postgres write is.
    pub(super) fn put_heads(
        &self,
        config: &LineageConfig,
        mutations: &[Mutation<'_>],
    ) -> Result<(), StoreError> {
        let mut data = self.write();
        apply_heads(&mut data, config, mutations)
    }

    /// The Memory side of `amend_head`: the domain lock held while `decide` reads and the write
    /// lands, so two amendments never interleave.
    pub(super) async fn amend_head<T>(
        &self,
        config: &LineageConfig,
        aggregate: &str,
        storage_name: &str,
        decide: impl FnOnce(&[(String, serde_json::Value)]) -> (T, Option<(String, serde_json::Value)>),
    ) -> Result<T, StoreError> {
        let _unit = self.begin().await;
        let rows = self.head_all(&config.domain, storage_name);
        let (answer, write) = decide(&rows);
        if let Some((id, state)) = write {
            let mutation = Mutation {
                aggregate,
                id: &id,
                operation: "save",
                state: &state,
            };
            self.put_heads(config, std::slice::from_ref(&mutation))?;
        }
        Ok(answer)
    }

    /// Records a delivery that failed every retry.
    pub(super) fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) {
        self.write().dead_letters.push(DeadLetterRecord {
            policy: dead_letter.policy.to_string(),
            target_domain: dead_letter.target_domain.to_string(),
            target_verb: dead_letter.target_verb.to_string(),
            payload: dead_letter.payload.clone(),
            error: dead_letter.error.to_string(),
            attempts: dead_letter.attempts,
        });
    }

    /// The delivery failures recorded so far.
    #[must_use]
    pub fn dead_letters(&self) -> Vec<DeadLetterRecord> {
        self.read().dead_letters.clone()
    }

    fn next_ordinal(&self) -> i64 {
        self.read().journal.last().map_or(1, |row| row.ordinal + 1)
    }

    pub(super) fn read(&self) -> std::sync::RwLockReadGuard<'_, Data> {
        self.shared
            .data
            .read()
            .unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn write(&self) -> std::sync::RwLockWriteGuard<'_, Data> {
        self.shared
            .data
            .write()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// Makes the next commits fail at `fault`, until [`MemoryStore::clear_fault`].
    #[cfg(test)]
    pub fn inject_fault(&self, fault: Fault) {
        *self
            .shared
            .fault
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(fault);
    }

    /// Lets commits succeed again.
    #[cfg(test)]
    pub fn clear_fault(&self) {
        *self
            .shared
            .fault
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = None;
    }

    /// Holds the domain lock as a competing writer would, until the guard drops.
    #[cfg(test)]
    pub async fn hold_lock(&self) -> OwnedMutexGuard<()> {
        Arc::clone(&self.shared.lock).lock_owned().await
    }

    /// Every committed row as `(ordinal, verb, args)`, the snapshot and the live sagas.
    #[cfg(test)]
    pub fn committed(&self) -> Committed {
        let data = self.read();
        let rows = data.journal.iter().map(|row| {
            let verb = row.step["verb"].as_str().unwrap_or_default().to_string();
            (row.ordinal, verb, row.step["args"].clone())
        });
        (
            rows.collect(),
            data.snapshot.clone(),
            data.sagas.values().cloned().collect(),
        )
    }

    /// Appends a journal row the snapshot does not cover.
    #[cfg(test)]
    pub fn append_unsnapshotted(&self, verb: &str, args: &serde_json::Value) {
        let ordinal = self.next_ordinal();
        let mut data = self.write();
        let step = serde_json::json!({ "verb": verb, "args": args });
        data.journal.push(Row { ordinal, step });
    }

    /// Rewrites the snapshot's seed.
    #[cfg(test)]
    pub fn replace_seed(&self, seed: serde_json::Value) {
        if let Some(snapshot) = self.write().snapshot.as_mut() {
            snapshot.seed = seed;
        }
    }

    /// Resets to a snapshot written before saga durability: latch unset, no sagas.
    #[cfg(test)]
    pub fn forget_saga_backfill(&self) {
        let mut data = self.write();
        if let Some(snapshot) = data.snapshot.as_mut() {
            snapshot.sagas_backfilled = false;
        }
        data.sagas.clear();
    }

    fn fails_at(&self, point: Fault) -> Result<(), StoreError> {
        let armed = *self
            .shared
            .fault
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if armed == Some(point) {
            return Err(StoreError::Backend(anyhow::anyhow!(
                "injected write failure"
            )));
        }
        Ok(())
    }
}

impl Default for MemoryStore {
    fn default() -> Self {
        Self::new()
    }
}

/// Checks every mutation, then applies them all, so a refused one leaves the heads as they were.
fn apply_heads(
    data: &mut Data,
    config: &LineageConfig,
    mutations: &[Mutation<'_>],
) -> Result<(), StoreError> {
    if config.era.is_none() && !mutations.is_empty() {
        return Err(StoreError::Backend(anyhow::anyhow!(
            "cannot append a lineage mutation for {}: no era is active",
            config.domain
        )));
    }
    if let Some(bad) = mutations.iter().find(|m| m.operation != "save") {
        return Err(StoreError::Backend(anyhow::anyhow!(
            "unsupported operation {:?}: only \"save\" is generated today",
            bad.operation
        )));
    }
    for mutation in mutations {
        let key = (config.domain.clone(), storage_name(mutation.aggregate));
        data.heads
            .entry(key)
            .or_default()
            .insert(mutation.id.to_string(), mutation.state.clone());
    }
    Ok(())
}

fn steps_after(data: &Data, ordinal: Option<i64>) -> Vec<serde_json::Value> {
    data.journal
        .iter()
        .filter(|row| ordinal.is_none_or(|after| row.ordinal > after))
        .map(|row| row.step.clone())
        .collect()
}

/// The domain lock, held until the unit commits, rolls back or drops.
pub struct MemoryUnit {
    store: MemoryStore,
    _guard: OwnedMutexGuard<()>,
}

impl MemoryUnit {
    /// Snapshot, replay steps and sagas as committed, which no one else can change meanwhile.
    pub(super) fn load(&self) -> State {
        let data = self.store.read();
        let snapshot = data.snapshot.clone();
        let mut state = State {
            snapshot,
            steps: Vec::new(),
            sagas: data.sagas.values().cloned().collect(),
        };
        let after = (!state.needs_saga_backfill())
            .then(|| state.snapshot.as_ref().map(|s| s.ordinal))
            .flatten();
        state.steps = steps_after(&data, after);
        state
    }

    /// Stages every write, then applies them together, the lineage mutations among them.
    pub(super) fn commit(self, accepted: &Accepted<'_>) -> Result<(), StoreError> {
        let store = &self.store;
        let ordinal = store.next_ordinal();
        let row = Row {
            ordinal,
            step: serde_json::json!({ "verb": accepted.verb, "args": accepted.args }),
        };
        store.fails_at(Fault::Snapshot)?;
        let snapshot = Snapshot {
            ordinal,
            seed: accepted.new_seed.clone(),
            sagas_backfilled: true,
        };
        store.fails_at(Fault::AfterSagas)?;
        let mut data = store.write();
        data.journal.push(row);
        data.snapshot = Some(snapshot);
        for saga in &accepted.saga_upserts {
            let key = (saga.process_manager.clone(), saga.correlation.clone());
            data.sagas.insert(key, saga.clone());
        }
        for key in &accepted.saga_deletes {
            data.sagas.remove(key);
        }
        if let Some(lineage) = &accepted.lineage {
            apply_heads(&mut data, lineage.config, &lineage.mutations)?;
        }
        Ok(())
    }
}

#[async_trait::async_trait]
impl super::Backend for MemoryStore {
    async fn begin<'a>(
        &'a self,
        _domain: &str,
    ) -> Result<Box<dyn super::UnitBackend + 'a>, StoreError> {
        Ok(Box::new(MemoryStore::begin(self).await))
    }

    async fn read_state(&self) -> Result<State, StoreError> {
        Ok(MemoryStore::read_state(self))
    }

    async fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) -> Result<(), StoreError> {
        MemoryStore::record_dead_letter(self, dead_letter);
        Ok(())
    }

    async fn head_by_id(
        &self,
        domain: &str,
        storage_name: &str,
        id: &str,
    ) -> Result<Option<serde_json::Value>, StoreError> {
        Ok(MemoryStore::head_by_id(self, domain, storage_name, id))
    }

    async fn head_all(
        &self,
        domain: &str,
        storage_name: &str,
    ) -> Result<Vec<(String, serde_json::Value)>, StoreError> {
        Ok(MemoryStore::head_all(self, domain, storage_name))
    }

    async fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> Result<Vec<serde_json::Value>, StoreError> {
        Ok(MemoryStore::head_states(self, domains, storage_name))
    }

    async fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Result<Option<serde_json::Value>, StoreError> {
        Ok(MemoryStore::head_find(self, domains, storage_name, matches))
    }

    async fn put_head(
        &self,
        config: &LineageConfig,
        mutation: &Mutation<'_>,
    ) -> Result<(), StoreError> {
        self.put_heads(config, std::slice::from_ref(mutation))
    }

    async fn amend_head(
        &self,
        config: &LineageConfig,
        _domain: &str,
        aggregate: &str,
        storage_name: &str,
        decide: &mut (dyn for<'r> FnMut(
            &'r [(String, serde_json::Value)],
        ) -> Option<(String, serde_json::Value)>
                  + Send),
    ) -> Result<(), StoreError> {
        MemoryStore::amend_head(
            self,
            config,
            aggregate,
            storage_name,
            |rows: &[(String, serde_json::Value)]| ((), decide(rows)),
        )
        .await
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

#[async_trait::async_trait]
impl super::UnitBackend for MemoryUnit {
    async fn load(&self) -> Result<State, StoreError> {
        Ok(MemoryUnit::load(self))
    }

    async fn commit(self: Box<Self>, accepted: Accepted<'_>) -> Result<(), StoreError> {
        (*self).commit(&accepted)
    }

    async fn rollback(self: Box<Self>) -> Result<(), StoreError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ping() -> serde_json::Value {
        serde_json::json!({})
    }

    async fn commit_one(store: &MemoryStore) {
        let args = ping();
        let accepted = Accepted {
            verb: "Ping",
            args: &args,
            new_seed: ping(),
            saga_upserts: Vec::new(),
            saga_deletes: Vec::new(),
            lineage: None,
        };
        store.begin().await.commit(&accepted).unwrap();
    }

    #[tokio::test]
    async fn stores_for_different_schemas_of_one_domain_do_not_share_a_journal() {
        let (first, second) = (
            MemoryStore::open("Tenants", Some("one")),
            MemoryStore::open("Tenants", Some("two")),
        );
        commit_one(&first).await;
        assert_eq!(first.committed().0.len(), 1);
        assert!(second.committed().0.is_empty());
    }

    #[tokio::test]
    async fn opening_the_same_domain_and_schema_twice_shares_the_data() {
        let first = MemoryStore::open("Shared", None);
        commit_one(&first).await;
        assert_eq!(MemoryStore::open("Shared", None).committed().0.len(), 1);
    }

    #[test]
    fn a_dead_letter_is_kept_outside_the_journal() {
        let store = MemoryStore::new();
        let payload = ping();
        store.record_dead_letter(&DeadLetter {
            policy: "P",
            target_domain: "D",
            target_verb: "V",
            payload: &payload,
            error: "down",
            attempts: 3,
        });
        assert_eq!(store.dead_letters()[0].attempts, 3);
        assert!(store.committed().0.is_empty());
    }
}
