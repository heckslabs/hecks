//! The port between the host and wherever a domain's journal lives.
//!
//! A [`Store`] holds one domain's flat journal of accepted commands, the snapshot caching the
//! kernel's last `instances`, and the live saga rows. Everything a dispatch writes goes through
//! one [`Unit`]: it takes the domain lock, loads the state to replay, and either commits the
//! journal row, snapshot, saga changes and lineage mutations together or, dropped, writes
//! nothing. Reads take no lock.
//!
//! The kernel is not part of this port: it is a pure function from state and steps to an
//! answer. A store never runs it and never stamps or rewrites what it is given.
//!
//! Eras, lineage heads, minting and the member lookups over head views exist only on Postgres,
//! so they are a capability ([`Store::lineage`]) a backend may lack, not a part of every store.

/// The journal's SQL: the Postgres adapter's reads and writes, with the journal's data re-exported.
pub mod journal_sql;
mod memory;
/// Era minting: the Postgres adapter's provisioning of eras, heads and lineage.
pub mod mint;
mod postgres;

use crate::journal::{LineageConfig, Mutation, SagaRow, Snapshot};
pub use memory::{DeadLetterRecord, Fault as MemoryFault, MemoryStore, MemoryUnit};
pub use postgres::{LineageStore, PostgresStore, PostgresUnit};
use tokio_postgres::Client;

/// Why a store call failed.
#[derive(Debug)]
pub enum StoreError {
    /// The tables or views the call reads are not there: a domain nobody has provisioned.
    NotProvisioned(anyhow::Error),
    /// This backend does not offer the named capability.
    Unsupported(&'static str),
    /// Any other failure of the backend, carrying its own message.
    Backend(anyhow::Error),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotProvisioned(e) | Self::Backend(e) => std::fmt::Display::fmt(e, f),
            Self::Unsupported(what) => write!(f, "this store has no {what}"),
        }
    }
}

impl std::error::Error for StoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::NotProvisioned(e) | Self::Backend(e) => {
                AsRef::<dyn std::error::Error + Send + Sync>::as_ref(e).source()
            }
            Self::Unsupported(_) => None,
        }
    }
}

impl StoreError {
    /// Whether the call failed because the store was never provisioned.
    #[must_use]
    pub const fn is_not_provisioned(&self) -> bool {
        matches!(self, Self::NotProvisioned(_))
    }
}

impl From<anyhow::Error> for StoreError {
    fn from(error: anyhow::Error) -> Self {
        let missing = error
            .chain()
            .filter_map(|cause| cause.downcast_ref::<tokio_postgres::Error>())
            .any(|db| db.code() == Some(&tokio_postgres::error::SqlState::UNDEFINED_TABLE));
        if missing {
            Self::NotProvisioned(error)
        } else {
            Self::Backend(error)
        }
    }
}

impl From<tokio_postgres::Error> for StoreError {
    fn from(error: tokio_postgres::Error) -> Self {
        anyhow::Error::from(error).into()
    }
}

/// What a dispatch or a read replays: the snapshot (if any), the journal steps to replay on
/// top of it, and the live sagas.
pub struct State {
    pub snapshot: Option<Snapshot>,
    /// The steps after the snapshot, or every step when there is no snapshot or it must be
    /// rebuilt (see [`State::needs_saga_backfill`]).
    pub steps: Vec<serde_json::Value>,
    /// Empty from [`Store::read_state`], which does not load sagas.
    pub sagas: Vec<SagaRow>,
}

impl State {
    /// Whether a full replay from an empty seed must stand in for the snapshot: true only for a
    /// snapshot written before saga durability, which never carried the sagas it implies.
    #[must_use]
    pub fn needs_saga_backfill(&self) -> bool {
        self.snapshot.as_ref().is_some_and(|s| !s.sagas_backfilled)
    }

    /// The seed `steps` replay onto: the snapshot's, or empty when there is none or it is
    /// being rebuilt.
    #[must_use]
    pub fn seed(&self) -> serde_json::Value {
        match &self.snapshot {
            Some(s) if !self.needs_saga_backfill() => s.seed.clone(),
            _ => serde_json::json!({}),
        }
    }
}

/// The accepted command a [`Unit`] persists, with everything the kernel said to persist with it.
pub struct Accepted<'a> {
    /// The verb journaled for replay.
    pub verb: &'a str,
    /// The arguments journaled for replay, exactly as the kernel ran them.
    pub args: &'a serde_json::Value,
    /// The kernel's `instances` after this step, becoming the snapshot.
    pub new_seed: serde_json::Value,
    pub saga_upserts: Vec<SagaRow>,
    /// `(process_manager, correlation)` of each saga that ended.
    pub saga_deletes: Vec<(String, String)>,
    /// The lineage mutations this step produced; `None` when the domain keeps no lineage.
    pub lineage: Option<LineageWrite<'a>>,
}

/// The lineage mirror writes of one step.
pub struct LineageWrite<'a> {
    pub config: &'a LineageConfig,
    pub mutations: Vec<Mutation<'a>>,
}

/// A cross-domain delivery that exhausted its retries, recorded outside any [`Unit`].
pub struct DeadLetter<'a> {
    pub policy: &'a str,
    pub target_domain: &'a str,
    pub target_verb: &'a str,
    pub payload: &'a serde_json::Value,
    pub error: &'a str,
    pub attempts: i32,
}

/// What a journal backend offers the host: the atomic scope a dispatch writes in, the lock-free
/// read, the dead-letter row and the head rows. The host reaches a backend only through this trait,
/// so it names no driver; the adapters implement it.
#[async_trait::async_trait]
pub trait Backend: Send + Sync {
    /// Takes the lock of `domain` and opens the scope a dispatch writes in.
    async fn begin<'a>(&'a self, domain: &str) -> Result<Box<dyn UnitBackend + 'a>, StoreError>;

    /// The state a read replays, taking no domain lock.
    async fn read_state(&self) -> Result<State, StoreError>;

    /// Records a delivery that failed every retry.
    async fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) -> Result<(), StoreError>;

    /// One aggregate's head row `id`; `None` when there is none.
    async fn head_by_id(
        &self,
        domain: &str,
        storage_name: &str,
        id: &str,
    ) -> Result<Option<serde_json::Value>, StoreError>;

    /// Every head row of one aggregate, in id byte order.
    async fn head_all(
        &self,
        domain: &str,
        storage_name: &str,
    ) -> Result<Vec<(String, serde_json::Value)>, StoreError>;

    /// Every head state from the first of `domains` that keeps the aggregate, in id byte order.
    async fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> Result<Vec<serde_json::Value>, StoreError>;

    /// The head row whose `matches` fields all hold; the first of `domains` that keeps heads decides.
    async fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Result<Option<serde_json::Value>, StoreError>;

    /// Writes one head row as its own step.
    async fn put_head(
        &self,
        config: &LineageConfig,
        mutation: &Mutation<'_>,
    ) -> Result<(), StoreError>;

    /// Reads one aggregate's head rows and lets `decide` answer with at most one `(id, state)` to
    /// save, with no other writer of the domain's heads between the read and the write.
    async fn amend_head(
        &self,
        config: &LineageConfig,
        domain: &str,
        aggregate: &str,
        storage_name: &str,
        decide: &mut (dyn for<'r> FnMut(
            &'r [(String, serde_json::Value)],
        ) -> Option<(String, serde_json::Value)>
                  + Send),
    ) -> Result<(), StoreError>;

    /// The concrete backend, for the adapters' own tools and for test fixtures.
    fn as_any(&self) -> &dyn std::any::Any;
}

/// What a backend's atomic scope offers: load, then commit or roll back. Dropping it unfinished
/// writes nothing.
#[async_trait::async_trait]
pub trait UnitBackend: Send + Sync {
    /// Loads what the dispatch replays and the sagas it starts from, inside the scope.
    async fn load(&self) -> Result<State, StoreError>;

    /// Persists the accepted command and everything with it, then ends the scope.
    async fn commit(self: Box<Self>, accepted: Accepted<'_>) -> Result<(), StoreError>;

    /// Ends the scope with nothing persisted.
    async fn rollback(self: Box<Self>) -> Result<(), StoreError>;
}

/// One domain's journal, snapshot and sagas, behind whichever backend the host booted with.
pub struct Store {
    backend: Box<dyn Backend>,
}

impl Store {
    /// A store over `backend`.
    #[must_use]
    pub fn new(backend: impl Backend + 'static) -> Self {
        Self {
            backend: Box::new(backend),
        }
    }

    /// A store over one Postgres connection, whose mutex serializes every use of it.
    #[must_use]
    pub fn postgres(client: Client) -> Self {
        Self::new(PostgresStore::new(client))
    }

    /// A store over `memory`, which a sibling handle may share.
    #[must_use]
    pub fn memory(memory: MemoryStore) -> Self {
        Self::new(memory)
    }

    /// Takes the lock of `domain` and opens the atomic scope a dispatch writes in.
    ///
    /// The lock covers the whole load-run-commit sequence, so two writers never both replay
    /// against the same prior steps. Dropping the unit without committing writes nothing.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the lock or the scope cannot be opened.
    pub async fn begin(&self, domain: &str) -> Result<Unit<'_>, StoreError> {
        Ok(Unit {
            inner: self.backend.begin(domain).await?,
        })
    }

    /// The state a read replays, taking no domain lock.
    ///
    /// Unlike [`Unit::load`] it ignores the saga latch and loads no sagas: a read reports the
    /// snapshot as it stands, plus any steps journaled after it.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the journal cannot be read.
    pub async fn read_state(&self) -> Result<State, StoreError> {
        self.backend.read_state().await
    }

    /// Records a delivery that failed every retry. Written after the command committed, so a
    /// failure here never undoes it.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the row cannot be written.
    pub async fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) -> Result<(), StoreError> {
        self.backend.record_dead_letter(dead_letter).await
    }

    /// The Postgres adapter's own connection handle, for minting, seals and operator tools;
    /// code that runs a domain uses the head methods and never this.
    #[must_use]
    pub fn lineage(&self) -> Option<&LineageStore> {
        self.backend
            .as_any()
            .downcast_ref::<PostgresStore>()
            .map(PostgresStore::lineage)
    }

    /// One aggregate's head row `id`, translated to its current shape; `None` when there is none.
    pub async fn head_by_id(
        &self,
        domain: &str,
        storage_name: &str,
        id: &str,
    ) -> Result<Option<serde_json::Value>, StoreError> {
        self.backend.head_by_id(domain, storage_name, id).await
    }

    /// Every head row of one aggregate, with its id.
    pub async fn head_all(
        &self,
        domain: &str,
        storage_name: &str,
    ) -> Result<Vec<(String, serde_json::Value)>, StoreError> {
        self.backend.head_all(domain, storage_name).await
    }

    /// Every head state of one aggregate, from the first of `domains` that keeps it; empty when
    /// none does.
    pub async fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> Result<Vec<serde_json::Value>, StoreError> {
        self.backend.head_states(domains, storage_name).await
    }

    /// The head row whose `matches` hold, each `(field, value)` naming a single-attribute value
    /// object. The first of `domains` that keeps heads for the aggregate decides.
    pub async fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Result<Option<serde_json::Value>, StoreError> {
        self.backend.head_find(domains, storage_name, matches).await
    }

    /// Reads one aggregate's head rows and lets `decide` answer with at most one `(id, state)` to
    /// save, atomically with the read: no other writer of the domain's heads gets between them.
    /// `domain` is the name the head views are qualified by and `config.domain` the journal's.
    pub async fn amend_head<T: Send>(
        &self,
        config: &LineageConfig,
        domain: &str,
        aggregate: &str,
        storage_name: &str,
        decide: impl FnOnce(&[(String, serde_json::Value)]) -> (T, Option<(String, serde_json::Value)>)
            + Send,
    ) -> Result<T, StoreError> {
        let mut decide = Some(decide);
        let mut answer = None;
        self.backend
            .amend_head(config, domain, aggregate, storage_name, &mut |rows| {
                let (settled, write) = decide.take().expect("a decision is made once")(rows);
                answer = Some(settled);
                write
            })
            .await?;
        Ok(answer.expect("the backend asked for the decision"))
    }

    /// Writes one head row outside a dispatch, as its own step.
    pub async fn put_head(
        &self,
        config: &LineageConfig,
        mutation: &Mutation<'_>,
    ) -> Result<(), StoreError> {
        self.backend.put_head(config, mutation).await
    }

    /// Every journaled step in order, whichever backend holds them.
    #[cfg(test)]
    pub async fn journal_steps(&self) -> Vec<serde_json::Value> {
        if let Some(store) = self.backend.as_any().downcast_ref::<PostgresStore>() {
            let guard = store.lineage().lock().await;
            return journal_sql::load_steps(&*guard).await.unwrap();
        }
        let memory = self.backend.as_any().downcast_ref::<MemoryStore>();
        memory
            .expect("a Postgres or Memory store")
            .committed()
            .0
            .into_iter()
            .map(|(_, verb, args)| serde_json::json!({ "verb": verb, "args": args }))
            .collect()
    }

    /// Every dead letter as `(policy, target_domain, target_verb, attempts)`, ordered by policy.
    #[cfg(test)]
    pub async fn dead_letter_rows(&self) -> Vec<(String, String, String, i32)> {
        if let Some(store) = self.backend.as_any().downcast_ref::<PostgresStore>() {
            let guard = store.lineage().lock().await;
            let sql = "SELECT policy, target_domain, target_verb, attempts \
                       FROM hecks_cross_domain_dead_letters ORDER BY policy";
            let rows = guard.query(sql, &[]).await.unwrap();
            return rows
                .iter()
                .map(|r| (r.get(0), r.get(1), r.get(2), r.get(3)))
                .collect();
        }
        let memory = self.backend.as_any().downcast_ref::<MemoryStore>();
        let mut rows: Vec<_> = memory
            .expect("a Postgres or Memory store")
            .dead_letters()
            .into_iter()
            .map(|d| (d.policy, d.target_domain, d.target_verb, d.attempts))
            .collect();
        rows.sort();
        rows
    }

    /// The raw connection, for test fixtures and assertions that reach beneath the seam.
    #[cfg(test)]
    pub async fn lock(&self) -> tokio::sync::MutexGuard<'_, Client> {
        match self.lineage() {
            Some(lineage) => lineage.lock().await,
            None => panic!("a memory store has no connection to lock"),
        }
    }
}

/// The atomic scope of one dispatch, holding the domain lock until it commits or drops.
pub struct Unit<'a> {
    inner: Box<dyn UnitBackend + 'a>,
}

impl Unit<'_> {
    /// Loads what the dispatch replays and the sagas it starts from, inside the scope.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the journal, snapshot or sagas cannot be read.
    pub async fn load(&self) -> Result<State, StoreError> {
        self.inner.load().await
    }

    /// Persists the accepted command and everything with it, then ends the scope.
    ///
    /// # Errors
    ///
    /// Returns the backend's error from the first write that fails; nothing is persisted.
    pub async fn commit(self, accepted: Accepted<'_>) -> Result<(), StoreError> {
        self.inner.commit(accepted).await
    }

    /// Ends the scope with nothing persisted, for a command the kernel refused.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the scope cannot be closed.
    pub async fn rollback(self) -> Result<(), StoreError> {
        self.inner.rollback().await
    }
}
