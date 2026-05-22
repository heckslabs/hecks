//! LazyRepository — deferred-hydration wrapper around Repository
//!
//! [antibody-exempt: rust/src/runtime/lazy_repository.rs — kernel-floor
//!  runtime perf ; OnceCell wrapper deferring Repository::load_persisted
//!  to first access. Same kernel-surface concern as sibling
//!  repository.rs ; a bluebook can't describe its storage substrate's
//!  boot timing.]
//!
//! Boot used to construct + hydrate ALL aggregate repositories eagerly
//! (Repository::new_with_context calls load_persisted in its
//! constructor, which does up to 2x heki::read per aggregate). With
//! 458 aggregates in the full conception that cost ~4.2s at boot — the
//! dominant share of a ~5.3s cold single-shot dispatch — even though a
//! single dispatch touches exactly ONE repository.
//!
//! LazyRepository holds the construction parameters and a
//! `OnceCell<Repository>`. The real Repository (and its load_persisted
//! disk read) is materialised on FIRST access, not at boot. A
//! single-shot dispatch hydrates one repo ; a long-running daemon
//! hydrates each repo on first touch and keeps it warm thereafter —
//! same end-state, the cost is paid lazily and only for what's used.
//!
//! The forwarding methods mirror Repository's surface so existing call
//! sites (`repo.find(id)`, `repo.save(...)`, `repo.all()`, ...) work
//! unchanged whether they hold `&LazyRepository` or `&mut
//! LazyRepository`. Read methods route through `OnceCell::get_or_init`
//! (takes `&self`) so the `Runtime::find`/`Runtime::all`/query paths
//! that borrow `&self` still hydrate transparently — no `&self`->`&mut
//! self` cascade up through the runtime.
//!
//! `Repository::new_with_context`'s own eager semantics are unchanged
//! (anything that constructs a Repository directly still hydrates in
//! the constructor) — laziness lives only at this boot-map layer.
//!
//! Usage:
//!   let lazy = LazyRepository::new("Heartbeat", data_dir, Some("name".into()), None);
//!   let state = lazy.find("heartbeat");      // hydrates on first call
//!   lazy_mut.save(state, ctx);               // hydrates if not yet


use super::repository::Repository;
use super::AggregateState;
use super::Value;
use crate::heki;
use std::cell::OnceCell;
use std::collections::HashMap;

pub struct LazyRepository {
    aggregate_type: String,
    data_dir: Option<String>,
    identified_by: Option<String>,
    context: Option<String>,
    cell: OnceCell<Repository>,
}

impl LazyRepository {
    /// Construct a lazy wrapper. Stores the params ; does NOT touch
    /// disk. The first `repo()` / `repo_mut()` call materialises the
    /// real Repository via `Repository::new_with_context`, which runs
    /// `load_persisted` then.
    pub fn new(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
    ) -> Self {
        LazyRepository {
            aggregate_type: aggregate_type.to_string(),
            data_dir,
            identified_by,
            context,
            cell: OnceCell::new(),
        }
    }

    /// Hydrate-on-first-access. `OnceCell::get_or_init` takes `&self`,
    /// so this is callable from `&self` runtime paths (find/all/query).
    fn repo(&self) -> &Repository {
        self.cell.get_or_init(|| {
            Repository::new_with_context(
                &self.aggregate_type,
                self.data_dir.clone(),
                self.identified_by.clone(),
                self.context.clone(),
            )
        })
    }

    /// Mutable hydrate-on-first-access. Forces the cell (via the `&self`
    /// initialiser) then hands back the `&mut` — `get_mut` returns the
    /// already-initialised value.
    fn repo_mut(&mut self) -> &mut Repository {
        // Ensure initialised. `get_or_init` only needs `&self` ; the
        // subsequent `get_mut().unwrap()` is infallible because the
        // cell is now populated.
        let _ = self.repo();
        self.cell.get_mut().expect("cell initialised by repo() above")
    }

    /// Whether the underlying Repository has been hydrated yet. Used by
    /// `hydrate_all` to skip already-warm repos and by the teardown
    /// story (un-hydrated cells drop for free).
    pub fn is_hydrated(&self) -> bool {
        self.cell.get().is_some()
    }

    // ----- forwarded Repository surface (read : &self) -----

    pub fn find(&self, id: &str) -> Option<&AggregateState> {
        self.repo().find(id)
    }

    pub fn all(&self) -> Vec<&AggregateState> {
        self.repo().all()
    }

    pub fn count(&self) -> usize {
        self.repo().count()
    }

    pub fn next_id_value(&self) -> u64 {
        self.repo().next_id_value()
    }

    // ----- forwarded Repository surface (mutate : &mut self) -----

    pub fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        self.repo_mut().find_mut(id)
    }

    pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        self.repo_mut().id_for_command(attrs)
    }

    pub fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) {
        self.repo_mut().save(state, ctx)
    }

    pub fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) {
        self.repo_mut().delete(id, ctx)
    }

    pub fn refresh_from_heki(&mut self) {
        self.repo_mut().refresh_from_heki()
    }

    pub fn seed_record(&mut self, state: AggregateState) {
        self.repo_mut().seed_record(state)
    }

    pub fn set_next_id(&mut self, value: u64) {
        self.repo_mut().set_next_id(value)
    }
}
