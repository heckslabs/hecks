//! PersistenceAdapter — the persistence PORT (hexagon driven side).
//!
//! A storage substrate an aggregate's repository can be wired to via the
//! hexagon `persisted_by("X")` binding. The kernel holds every WIRED backend
//! as a `Box<dyn PersistenceAdapter>` and NEVER names a concrete engine —
//! sqlite / postgres / parquet live in their own crates, each implementing
//! this trait, registered at the composition root (the cli) and resolved by
//! name at boot through the adapter registry (`adapter_registry`).
//!
//! The default in-process backends (heki / memory / append-log) are NOT
//! adapters in this sense : they are the zero-dependency substrate the kernel
//! always carries, expressed as concrete `Backend` variants in
//! `lazy_repository`. This port is the seam for the HEAVY, swappable, often
//! native-only backends that must not be compiled into the runtime crate.
//!
//! The method surface mirrors the `LazyRepository` forwarding API exactly, so
//! a `Box<dyn PersistenceAdapter>` is a drop-in for the in-process `Repository`
//! behind the same wrapper. Read methods take `&self` (and may return borrows
//! into the adapter's own storage) ; mutating methods take `&mut self`.
//!
//! `Send` is required because the runtime that owns the repository map crosses
//! threads on the actor substrate ; an adapter holding a non-`Send` handle
//! (e.g. a raw connection) must wrap it to satisfy the bound, exactly as the
//! in-tree sqlite backend did when it lived behind `Backend::Sql`.

use super::AggregateState;
use super::Value;
use crate::heki;
use crate::ir;
use std::collections::HashMap;

/// The persistence port. See the module header for the contract.
pub trait PersistenceAdapter: Send {
    /// Find one aggregate's state by id, borrowing from the adapter's store.
    fn find(&self, id: &str) -> Option<&AggregateState>;

    /// Mutable find — the dispatch path mutates the looked-up state in place.
    fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState>;

    /// Every aggregate state the adapter holds (read-side `all()` / query oracle).
    fn all(&self) -> Vec<&AggregateState>;

    /// How many aggregates the adapter holds.
    fn count(&self) -> usize;

    /// The next monotonic id value (counter-minted ids).
    fn next_id_value(&self) -> u64;

    /// Resolve / mint the id a command targets, given its attrs.
    fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String;

    /// Persist one aggregate state (upsert).
    fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>);

    /// Remove one aggregate state by id.
    fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>);

    /// The where() pushdown seam. `Some(candidates)` runs the adapter's own
    /// (e.g. connection-executed, injection-safe) prefilter ; `None` means no
    /// pushdown and the caller keeps the in-memory `all()` + oracle path. The
    /// oracle re-applies every clause regardless, so a `Some` prefilter can
    /// only narrow — parity holds by construction.
    fn query(
        &self,
        wheres: &[ir::WhereClause],
        attrs: &HashMap<String, String>,
    ) -> Option<Vec<AggregateState>>;

    /// Seed one already-built state without going through the save/write path
    /// (used by hydration / test fixtures).
    fn seed_record(&mut self, state: AggregateState);

    /// Force the next-id counter (used by hydration to resume the sequence).
    fn set_next_id(&mut self, value: u64);
}

// ─── adapter registry (the composition-root seam) ───────────────────────────
//
// The runtime resolves WIRED persistence bindings by name against a process-
// global registry. Concrete adapters (sqlite, future R2 / postgres) live in
// their OWN crates and register themselves at the composition root (the cli)
// BEFORE boot. The runtime crate names no engine — it only knows this trait
// and the registry token a hexagon's `persisted_by` binding refers to.

use crate::ir::Aggregate;
use std::sync::{Mutex, OnceLock};

/// What an adapter factory needs to build one aggregate's backend : the
/// aggregate's IR (so the adapter derives its OWN schema — the sqlite column
/// typing is sqlite's business, not the kernel's) and the per-deployment
/// options from the hexagon binding (e.g. `{"db": "/path/app.db"}`).
pub struct PersistenceSpec {
    pub aggregate: Aggregate,
    pub options: HashMap<String, String>,
}

impl PersistenceSpec {
    /// Convenience accessor for one option (e.g. `spec.option("db")`).
    pub fn option(&self, key: &str) -> Option<&str> {
        self.options.get(key).map(|s| s.as_str())
    }
}

/// A registered adapter constructor. FALLIBLE — a failed build refuses the
/// aggregate at boot (i735), never silently falls back to heki.
pub type AdapterFactory = fn(&PersistenceSpec) -> Result<Box<dyn PersistenceAdapter>, String>;

static REGISTRY: OnceLock<Mutex<HashMap<String, AdapterFactory>>> = OnceLock::new();

fn registry() -> &'static Mutex<HashMap<String, AdapterFactory>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Register a persistence adapter under the hexagon token it answers to (the
/// `persisted_by` / `adapter :<token>` name, e.g. `"sqlite"`). The composition
/// root calls this once at startup, before boot.
pub fn register_persistence_adapter(token: &str, factory: AdapterFactory) {
    registry()
        .lock()
        .expect("persistence adapter registry poisoned")
        .insert(token.to_string(), factory);
}

/// Resolve a registered factory by hexagon token. `None` when no adapter for
/// that token was registered — the aggregate keeps the in-process heki/memory
/// backend `boot` built.
pub fn persistence_adapter_factory(token: &str) -> Option<AdapterFactory> {
    registry()
        .lock()
        .expect("persistence adapter registry poisoned")
        .get(token)
        .copied()
}
