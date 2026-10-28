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

mod memory;

use crate::journal::{HeldEra, LineageConfig, Mutation, SagaRow, Snapshot};
pub use memory::{DeadLetterRecord, Fault as MemoryFault, MemoryStore, MemoryUnit};

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

/// Tells whether a failed call means the store was never provisioned. The backend that can tell
/// registers it once; with none registered every failure is a plain backend failure.
static NOT_PROVISIONED_PROBE: std::sync::OnceLock<fn(&anyhow::Error) -> bool> =
    std::sync::OnceLock::new();

impl StoreError {
    /// Registers the backend's test for "the tables or views are not there"; the first call wins.
    pub fn teach_not_provisioned(probe: fn(&anyhow::Error) -> bool) {
        let _ = NOT_PROVISIONED_PROBE.set(probe);
    }
}

impl From<anyhow::Error> for StoreError {
    fn from(error: anyhow::Error) -> Self {
        let missing = NOT_PROVISIONED_PROBE
            .get()
            .is_some_and(|probe| probe(&error));
        if missing {
            Self::NotProvisioned(error)
        } else {
            Self::Backend(error)
        }
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

    /// The head row whose `matches` fields all hold; the first of `domains` that keeps heads
    /// decides.
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

    /// The eras held for `domain`, oldest first: each names a shape this store has held.
    async fn held_eras(&self, domain: &str) -> Result<Vec<HeldEra>, StoreError>;

    /// The highest era held for `domain`; `None` when none is held.
    async fn current_era(&self, domain: &str) -> Result<Option<i32>, StoreError>;

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

    /// The concrete backend, for an adapter's own tools and for test fixtures that reach beneath
    /// the seam.
    #[must_use]
    pub fn backend(&self) -> &dyn Backend {
        &*self.backend
    }

    /// The eras held for `domain`, oldest first.
    pub async fn held_eras(&self, domain: &str) -> Result<Vec<HeldEra>, StoreError> {
        self.backend.held_eras(domain).await
    }

    /// The highest era held for `domain`; `None` when none is held.
    pub async fn current_era(&self, domain: &str) -> Result<Option<i32>, StoreError> {
        self.backend.current_era(domain).await
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
                let (settled, write) = decide.take()?(rows);
                answer = Some(settled);
                write
            })
            .await?;
        answer.ok_or_else(|| {
            StoreError::Backend(anyhow::anyhow!(
                "the backend never asked for the head decision"
            ))
        })
    }

    /// Writes one head row outside a dispatch, as its own step.
    pub async fn put_head(
        &self,
        config: &LineageConfig,
        mutation: &Mutation<'_>,
    ) -> Result<(), StoreError> {
        self.backend.put_head(config, mutation).await
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
