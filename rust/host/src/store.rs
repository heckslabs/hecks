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

/// One domain's journal, snapshot and sagas, behind whichever backend the host booted with.
pub enum Store {
    Postgres(PostgresStore),
    /// Process memory, for local runs and tests; nothing survives a restart.
    Memory(MemoryStore),
}

impl Store {
    /// A store over one Postgres connection, whose mutex serializes every use of it.
    #[must_use]
    pub fn postgres(client: Client) -> Self {
        Self::Postgres(PostgresStore::new(client))
    }

    /// A store over `memory`, which a sibling handle may share.
    #[must_use]
    pub const fn memory(memory: MemoryStore) -> Self {
        Self::Memory(memory)
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
        match self {
            Self::Postgres(store) => store.begin(domain).await.map(Unit::Postgres),
            Self::Memory(store) => Ok(Unit::Memory(store.begin().await)),
        }
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
        match self {
            Self::Postgres(store) => store.read_state().await,
            Self::Memory(store) => Ok(store.read_state()),
        }
    }

    /// Records a delivery that failed every retry. Written after the command committed, so a
    /// failure here never undoes it.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the row cannot be written.
    pub async fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) -> Result<(), StoreError> {
        match self {
            Self::Postgres(store) => store.record_dead_letter(dead_letter).await,
            Self::Memory(store) => {
                store.record_dead_letter(dead_letter);
                Ok(())
            }
        }
    }

    /// The era, head-view and member-lookup surface, on a backend that has one.
    #[must_use]
    pub const fn lineage(&self) -> Option<&LineageStore> {
        match self {
            Self::Postgres(store) => Some(store.lineage()),
            Self::Memory(_) => None,
        }
    }

    /// [`Store::lineage`] for a caller that cannot proceed without it.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::Unsupported`] on a backend without lineage.
    pub fn require_lineage(&self) -> Result<&LineageStore, StoreError> {
        self.lineage().ok_or(StoreError::Unsupported("lineage"))
    }

    /// Every journaled step in order, whichever backend holds them.
    #[cfg(test)]
    pub async fn journal_steps(&self) -> Vec<serde_json::Value> {
        match self {
            Self::Postgres(store) => {
                let guard = store.lineage().lock().await;
                crate::journal::load_steps(&*guard).await.unwrap()
            }
            Self::Memory(store) => store
                .committed()
                .0
                .into_iter()
                .map(|(_, verb, args)| serde_json::json!({ "verb": verb, "args": args }))
                .collect(),
        }
    }

    /// Every dead letter as `(policy, target_domain, target_verb, attempts)`, ordered by policy.
    #[cfg(test)]
    pub async fn dead_letter_rows(&self) -> Vec<(String, String, String, i32)> {
        match self {
            Self::Postgres(store) => {
                let guard = store.lineage().lock().await;
                let sql = "SELECT policy, target_domain, target_verb, attempts \
                           FROM hecks_cross_domain_dead_letters ORDER BY policy";
                let rows = guard.query(sql, &[]).await.unwrap();
                rows.iter()
                    .map(|r| (r.get(0), r.get(1), r.get(2), r.get(3)))
                    .collect()
            }
            Self::Memory(store) => {
                let mut rows: Vec<_> = store
                    .dead_letters()
                    .into_iter()
                    .map(|d| (d.policy, d.target_domain, d.target_verb, d.attempts))
                    .collect();
                rows.sort();
                rows
            }
        }
    }

    /// The raw connection, for test fixtures and assertions that reach beneath the seam.
    #[cfg(test)]
    pub async fn lock(&self) -> tokio::sync::MutexGuard<'_, Client> {
        match self {
            Self::Postgres(store) => store.lineage().lock().await,
            Self::Memory(_) => panic!("a memory store has no connection to lock"),
        }
    }
}

/// The atomic scope of one dispatch, holding the domain lock until it commits or drops.
pub enum Unit<'a> {
    Postgres(PostgresUnit<'a>),
    Memory(MemoryUnit),
}

impl Unit<'_> {
    /// Loads what the dispatch replays and the sagas it starts from, inside the scope.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the journal, snapshot or sagas cannot be read.
    pub async fn load(&self) -> Result<State, StoreError> {
        match self {
            Self::Postgres(unit) => unit.load().await,
            Self::Memory(unit) => Ok(unit.load()),
        }
    }

    /// Persists the accepted command and everything with it, then ends the scope.
    ///
    /// # Errors
    ///
    /// Returns the backend's error from the first write that fails; nothing is persisted.
    pub async fn commit(self, accepted: Accepted<'_>) -> Result<(), StoreError> {
        match self {
            Self::Postgres(unit) => unit.commit(accepted).await,
            Self::Memory(unit) => unit.commit(&accepted),
        }
    }

    /// Ends the scope with nothing persisted, for a command the kernel refused.
    ///
    /// # Errors
    ///
    /// Returns the backend's error when the scope cannot be closed.
    pub async fn rollback(self) -> Result<(), StoreError> {
        match self {
            Self::Postgres(unit) => unit.rollback().await,
            Self::Memory(_) => Ok(()),
        }
    }
}
