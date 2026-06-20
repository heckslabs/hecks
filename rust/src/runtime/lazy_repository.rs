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
use super::sqlite_repository::SqliteRepository;
use super::AggregateState;
use super::Value;
use crate::heki;
use std::cell::OnceCell;
use std::collections::HashMap;

/// SQL-backend construction params. Carried (not opened) until first
/// access — the same defer-the-disk-read discipline the heki backend
/// uses, so a single-shot dispatch only opens the one db it touches.
#[derive(Clone)]
pub struct SqliteConfig {
    pub aggregate_type: String,
    pub db_path: String,
    pub identified_by: Option<String>,
    /// `(attribute_name, sql_type)` pairs for the typed columns,
    /// derived from the bluebook IR by the runtime boot loop.
    pub columns: Vec<(String, String)>,
}

/// Which storage substrate a repository wraps. Chosen at construction
/// from the hecksagon's `persistence` declaration — heki/memory is the
/// default ; `adapter :sqlite, db:` selects Sql. Heki/memory defer their
/// first disk touch to first access via a OnceCell ; Sql is EAGER (built
/// at boot) because its construction is fallible (i735 defect 2).
enum Backend {
    /// The explicit in-memory adapter (`adapter :memory`). A pure in-process
    /// HashMap keyed by aggregate id, alive for the process, gone on restart.
    /// Distinct from `Heki { data_dir: None }` : memory is a wired CHOICE, not
    /// an implicit fallback. Reuses `Repository` with `data_dir = None` so every
    /// disk branch is skipped — no heki path is ever reached.
    Memory {
        aggregate_type: String,
        identified_by: Option<String>,
        context: Option<String>,
        cell: OnceCell<Repository>,
    },
    Heki {
        aggregate_type: String,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
        cell: OnceCell<Repository>,
    },
    /// The AppendLog adapter (`persisted_by("AppendLog")`) — the bluebook-
    /// first Event Log. READS exactly like Heki : a Repository hydrated from
    /// `data_dir`, the merge daemon's consolidated `event.heki`. SAVE is the
    /// sole divergence — append-not-upsert : each save persists one immutable
    /// record to THIS process's private shard (single-writer, lossless),
    /// folded into the global log by the merge. Same fields as Heki so every
    /// read arm shares Heki's behaviour ; only `save` overrides.
    AppendLog {
        aggregate_type: String,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
        cell: OnceCell<Repository>,
    },
    /// The SQL adapter (`adapter :sqlite, db:`). EAGER, unlike the lazy
    /// heki/memory cells : the `SqliteRepository` (open + CREATE TABLE +
    /// row-load) is built at boot by `Runtime::apply_sqlite_persistence`,
    /// because construction is FALLIBLE (i735 defect 2) and the infallible
    /// forwarded read surface (`find`/`save`) cannot host a deferred
    /// `Result`. A failed table-create never reaches here — that aggregate
    /// is refused at boot, not silently swapped to heki.
    Sql {
        repo: Box<SqliteRepository>,
    },
}

/// The persistence backend a `LazyRepository` resolved to — the read-only
/// discriminant `backend_kind()` exposes for the i728 backend-map gate (the
/// Phase-A enforcement check that no production domain silently changes backend).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Heki,
    Memory,
    Sql,
    AppendLog,
}

pub struct LazyRepository {
    backend: Backend,
}

impl LazyRepository {
    /// Construct a heki/memory-backed lazy wrapper. Stores the params ;
    /// does NOT touch disk. The first access materialises the real
    /// Repository via `Repository::new_with_context`, which runs
    /// `load_persisted` then.
    pub fn new(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
    ) -> Self {
        LazyRepository {
            backend: Backend::Heki {
                aggregate_type: aggregate_type.to_string(),
                data_dir,
                identified_by,
                context,
                cell: OnceCell::new(),
            },
        }
    }

    /// Construct the AppendLog adapter (`persisted_by("AppendLog")`). Same
    /// params + lazy cell as `new` (heki) — it READS from `data_dir` (the
    /// merged event.heki) identically ; only `save` diverges to append-to-shard.
    /// The shard dir is a `shards/` sibling of `data_dir`, resolved in `save`.
    pub fn new_appendlog(
        aggregate_type: &str,
        data_dir: Option<String>,
        identified_by: Option<String>,
        context: Option<String>,
    ) -> Self {
        LazyRepository {
            backend: Backend::AppendLog {
                aggregate_type: aggregate_type.to_string(),
                data_dir,
                identified_by,
                context,
                cell: OnceCell::new(),
            },
        }
    }

    /// Construct the explicit in-memory adapter (`adapter :memory`). A pure
    /// in-process HashMap keyed by aggregate id ; survives the process, vanishes
    /// on restart. The materialised Repository carries `data_dir = None`, so no
    /// disk read/write is ever performed. Distinct from `new(.., None, ..)` :
    /// memory is a deliberate, wired choice, not an implicit fallback.
    pub fn new_memory(
        aggregate_type: &str,
        identified_by: Option<String>,
        context: Option<String>,
    ) -> Self {
        LazyRepository {
            backend: Backend::Memory {
                aggregate_type: aggregate_type.to_string(),
                identified_by,
                context,
                cell: OnceCell::new(),
            },
        }
    }

    /// Wrap an ALREADY-constructed `SqliteRepository`. Unlike the heki/
    /// memory path this is EAGER : the repo (open + CREATE TABLE +
    /// row-load) is built by the caller (`apply_sqlite_persistence`) so a
    /// fallible table-create is decided at boot, not deferred behind a
    /// OnceCell the infallible read surface can't fail through.
    pub fn new_sqlite(repo: SqliteRepository) -> Self {
        LazyRepository {
            backend: Backend::Sql {
                repo: Box::new(repo),
            },
        }
    }

    /// Hydrate-on-first-access for the heki backend. `OnceCell::get_or_init`
    /// takes `&self`, so this is callable from `&self` runtime paths.
    fn repo(&self) -> &Repository {
        match &self.backend {
            Backend::Memory { aggregate_type, identified_by, context, cell } => {
                cell.get_or_init(|| {
                    // data_dir = None → pure in-memory ; no disk branch is reached.
                    Repository::new_with_context(
                        aggregate_type,
                        None,
                        identified_by.clone(),
                        context.clone(),
                    )
                })
            }
            Backend::Heki { aggregate_type, data_dir, identified_by, context, cell }
            | Backend::AppendLog { aggregate_type, data_dir, identified_by, context, cell } => {
                cell.get_or_init(|| {
                    Repository::new_with_context(
                        aggregate_type,
                        data_dir.clone(),
                        identified_by.clone(),
                        context.clone(),
                    )
                })
            }
            Backend::Sql { .. } => unreachable!("repo() on a SQL-backed LazyRepository"),
        }
    }

    /// Hydrate-on-first-access for the SQL backend. Same `&self`
    /// OnceCell contract as `repo()`.
    fn sql(&self) -> &SqliteRepository {
        match &self.backend {
            Backend::Sql { repo } => repo.as_ref(),
            Backend::Heki { .. } | Backend::Memory { .. } | Backend::AppendLog { .. } => {
                unreachable!("sql() on a non-SQL LazyRepository")
            }
        }
    }

    /// True when this wrapper is SQL-backed (selected by `adapter
    /// :sqlite`). Read methods branch on it to route to the right cell ;
    /// `apply_sqlite_persistence`'s per-context scoping test asserts on it
    /// (i735) to prove only the declaring domain's repos became SQL.
    pub fn is_sql(&self) -> bool {
        matches!(self.backend, Backend::Sql { .. })
    }

    /// The backend variant this repository resolved to, WITHOUT hydrating the
    /// OnceCell — a `&self` peek at the enum tag. Feeds `Runtime::dump_backend_map`,
    /// the i728 Phase-A gate asserting no production domain silently changes backend.
    pub fn backend_kind(&self) -> BackendKind {
        match &self.backend {
            Backend::Heki { .. } => BackendKind::Heki,
            Backend::Memory { .. } => BackendKind::Memory,
            Backend::Sql { .. } => BackendKind::Sql,
            Backend::AppendLog { .. } => BackendKind::AppendLog,
        }
    }

    /// The heki store dir this repository is rooted at, when heki-backed. `None`
    /// for memory (no disk) and sql (its own db path). Peeks without hydrating.
    pub fn heki_path(&self) -> Option<String> {
        match &self.backend {
            Backend::Heki { data_dir, .. } | Backend::AppendLog { data_dir, .. } => data_dir.clone(),
            _ => None,
        }
    }

    /// Mutable hydrate-on-first-access (heki). Forces the cell via the
    /// `&self` initialiser then hands back the `&mut`.
    fn repo_mut(&mut self) -> &mut Repository {
        let _ = self.repo();
        match &mut self.backend {
            Backend::Heki { cell, .. } | Backend::Memory { cell, .. } | Backend::AppendLog { cell, .. } => {
                cell.get_mut().expect("cell initialised by repo() above")
            }
            Backend::Sql { .. } => unreachable!("repo_mut() on a SQL-backed LazyRepository"),
        }
    }

    /// Mutable hydrate-on-first-access (SQL). Mirror of `repo_mut`.
    fn sql_mut(&mut self) -> &mut SqliteRepository {
        let _ = self.sql();
        match &mut self.backend {
            Backend::Sql { repo } => repo.as_mut(),
            Backend::Heki { .. } | Backend::Memory { .. } | Backend::AppendLog { .. } => {
                unreachable!("sql_mut() on a non-SQL LazyRepository")
            }
        }
    }

    /// Whether the underlying repository has been hydrated yet. Used by
    /// `hydrate_all` to skip already-warm repos and by the teardown
    /// story (un-hydrated cells drop for free).
    pub fn is_hydrated(&self) -> bool {
        match &self.backend {
            Backend::Heki { cell, .. } | Backend::Memory { cell, .. } | Backend::AppendLog { cell, .. } => cell.get().is_some(),
            // SQL is eager — built at boot, so always hydrated.
            Backend::Sql { .. } => true,
        }
    }

    // ----- forwarded repository surface (read : &self) -----

    pub fn find(&self, id: &str) -> Option<&AggregateState> {
        if self.is_sql() { self.sql().find(id) } else { self.repo().find(id) }
    }

    pub fn all(&self) -> Vec<&AggregateState> {
        if self.is_sql() { self.sql().all() } else { self.repo().all() }
    }

    pub fn count(&self) -> usize {
        if self.is_sql() { self.sql().count() } else { self.repo().count() }
    }

    pub fn next_id_value(&self) -> u64 {
        if self.is_sql() { self.sql().next_id_value() } else { self.repo().next_id_value() }
    }

    // ----- forwarded repository surface (mutate : &mut self) -----

    pub fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> {
        if self.is_sql() { self.sql_mut().find_mut(id) } else { self.repo_mut().find_mut(id) }
    }

    pub fn id_for_command(&mut self, attrs: &HashMap<String, Value>) -> String {
        if self.is_sql() { self.sql_mut().id_for_command(attrs) } else { self.repo_mut().id_for_command(attrs) }
    }

    pub fn save(&mut self, state: AggregateState, ctx: heki::WriteContext<'_>) {
        // AppendLog : append-not-upsert. The Event Log's save persists one
        // immutable shard record instead of overwriting a per-id row.
        if let Backend::AppendLog { data_dir, .. } = &self.backend {
            Self::append_log_save(&data_dir.clone(), &state);
            return;
        }
        if self.is_sql() { self.sql_mut().save(state, ctx) } else { self.repo_mut().save(state, ctx) }
    }

    /// AppendLog save — build one immutable shard record from the Event state
    /// and append it to THIS process's private shard (a `shards/` sibling of
    /// the merged event.heki). event_id + sequence were reserved at dispatch
    /// (record_event_append) and ride in `state`, so `append_record` writes
    /// the pre-stamped record. If the sink isn't open yet (a direct Append
    /// with no prior reserve), fall back to append_to_process_shard, which
    /// opens the sink + stamps a fresh id.
    fn append_log_save(data_dir: &Option<String>, state: &AggregateState) {
        use super::event_shard::{self, ShardRecord};
        let dir = match data_dir {
            Some(d) => d,
            None => return, // memory-backed AppendLog has no disk shard target
        };
        let shard_dir = std::path::Path::new(dir).join("shards");
        let s = |k: &str| state.get(k).as_str().unwrap_or_default().to_string();
        let sub = |k: &str, f: &str| match state.get(k) {
            Value::Map(m) => m.get(f).and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            _ => String::new(),
        };
        let seq = match state.get("sequence") {
            Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
            Value::Int(i) => *i,
            _ => 0,
        } as u64;
        let rec = ShardRecord {
            shard: event_shard::process_shard_id().to_string(),
            seq,
            ts: s("recorded_at"),
            event_id: s("event_id"),
            aggregate_name: s("aggregate_name"),
            aggregate_id: s("aggregate_id"),
            verb: sub("command", "verb"),
            inputs: sub("command", "inputs"),
            field: sub("delta", "field"),
            value: sub("delta", "value"),
            causation_id: s("causation_id"),
            correlation_id: s("correlation_id"),
            actor: s("actor"),
        };
        if !event_shard::append_record(&rec) {
            let _ = event_shard::append_to_process_shard(&shard_dir, rec);
        }
    }

    pub fn delete(&mut self, id: &str, ctx: heki::WriteContext<'_>) {
        if self.is_sql() { self.sql_mut().delete(id, ctx) } else { self.repo_mut().delete(id, ctx) }
    }

    /// Re-read from disk when a sibling process advanced the store.
    /// No-op for the SQL backend — every read goes to the live db
    /// connection, so there's no stale in-memory snapshot to refresh
    /// against (the heki cross-process freshness concern doesn't apply).
    pub fn refresh_from_heki(&mut self) {
        if !self.is_sql() { self.repo_mut().refresh_from_heki() }
    }

    pub fn seed_record(&mut self, state: AggregateState) {
        if self.is_sql() { self.sql_mut().seed_record(state) } else { self.repo_mut().seed_record(state) }
    }

    pub fn set_next_id(&mut self, value: u64) {
        if self.is_sql() { self.sql_mut().set_next_id(value) } else { self.repo_mut().set_next_id(value) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_backend_retains_within_process_and_vanishes_on_restart() {
        // The explicit in-memory stub : a HashMap keyed by aggregate id, alive
        // for the process, gone on restart. No disk is ever touched.
        let mut repo = LazyRepository::new_memory("Order", Some("id".into()), None);
        repo.save(
            AggregateState::new("order-1"),
            heki::WriteContext::OutOfBand { reason: "test" },
        );
        // Stored and retrievable by id within the process.
        assert!(repo.find("order-1").is_some());
        assert_eq!(repo.count(), 1);

        // A fresh memory repository (process "restart") starts empty — no disk
        // means nothing survives the new instance.
        let fresh = LazyRepository::new_memory("Order", Some("id".into()), None);
        assert!(fresh.find("order-1").is_none());
        assert_eq!(fresh.count(), 0);
    }
}
