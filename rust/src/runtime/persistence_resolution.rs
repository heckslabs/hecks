//! Runtime persistence resolution (i728) — the backend-map projection read
//! + the dormant is-wired check. GENERATED from codegen/runtime_shape (the
//! `ResolutionMethod` rows + snippets) by the runtime-as-bluebook strangler
//! file-split. Do NOT hand-edit ; edit the shape + snippets and run
//! `storehouse specialize persistence_resolution --output
//! rust/src/runtime/persistence_resolution.rs`.
//!
//! Inherent `impl Runtime` methods in a child module : child modules see the
//! parent's private fields + helpers, so these reach `self.repositories` /
//! `self.hecksagons` / `repo_key` directly.
//!
//! [antibody-exempt: rust/src/runtime/persistence_resolution.rs — GENERATED
//!  output of the runtime_shape specializer (runtime-as-bluebook strangler
//!  file-split, i728). The bluebook shape is the source ; this .rs is a
//!  golden-gated build artifact, not hand-written. Retires at the i78
//!  meta-shape like its specializer siblings.]

use super::*;

// apply_sqlite_persistence is the only #[cfg(not(wasm32))] method here and the
// only user of these two ; gate the imports to match so the wasm build carries
// no unused-import warning. Everything else resolves through the `super::*`
// glob (BackendInfo, LazyRepository, repo_key, the pub sqlite_* modules).
#[cfg(not(target_arch = "wasm32"))]
use std::collections::HashMap;
#[cfg(not(target_arch = "wasm32"))]
use super::lazy_repository;

impl Runtime {
    /// Snapshot every repository's resolved backend (kind + heki path) WITHOUT
    /// hydrating any of them. The i728 Phase-A enforcement gate diffs this
    /// before/after a change ; any unexpected backend flip is an automatic stop.
    /// Sorted by repo_key so the diff is deterministic.
    pub fn dump_backend_map(&self) -> Vec<BackendInfo> {
        let mut rows: Vec<BackendInfo> = self
            .repositories
            .iter()
            .map(|(key, repo)| BackendInfo {
                repo_key: key.clone(),
                kind: repo.backend_kind(),
                heki_path: repo.heki_path(),
            })
            .collect();
        rows.sort_by(|a, b| a.repo_key.cmp(&b.repo_key));
        rows
    }

    /// i728 DORMANT is-wired check — repo_keys of aggregates whose governing
    /// hecksagon declares NO persistence adapter (`persistence.is_none()`),
    /// i.e. would be UNWIRED. In Phase C a STRICT `.world` turns a non-empty
    /// result into a boot error ; here it is plumbing only — no caller
    /// enforces it, and `boot_in_memory` (the behaviors harness) bypasses it.
    /// A context is wired when some attached hecksagon names it AND declares
    /// a persistence adapter (mirrors `apply_sqlite_persistence`'s match).
    pub fn unwired_aggregates(&self) -> Vec<String> {
        let wired_contexts: std::collections::HashSet<&str> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.is_some())
            .map(|hex| hex.name.as_str())
            .collect();
        let mut out: Vec<String> = self
            .domain
            .aggregates
            .iter()
            .filter(|agg| {
                agg.context
                    .as_deref()
                    .map_or(true, |ctx| !wired_contexts.contains(ctx))
            })
            .map(|agg| repo_key(agg.context.as_deref(), &agg.name))
            .collect();
        out.sort();
        out
    }

    /// Replace every repository with an explicit `Backend::Memory` wrapper.
    /// Safe post-boot because the lazy repos are still un-hydrated (no disk
    /// touch yet) — the same swap `apply_per_domain_world_dirs` performs.
    pub(super) fn force_memory_repositories(&mut self) {
        let patches: Vec<(String, String, Option<String>, Option<String>)> = self
            .domain
            .aggregates
            .iter()
            .map(|agg| {
                (
                    repo_key(agg.context.as_deref(), &agg.name),
                    agg.name.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                )
            })
            .collect();
        for (key, name, identified_by, context) in patches {
            self.repositories
                .insert(key, LazyRepository::new_memory(&name, identified_by, context));
        }
    }

    /// Rebuild on the SQL backend ONLY those aggregates whose governing
    /// hecksagon declares `:sqlite` — matched by `agg.context ==
    /// hecksagon.name`. A hecksagon is a bluebook's companion file ; its
    /// name is the bluebook name, which the parser stamps as every
    /// aggregate's `context`. Typed columns derive from the bluebook IR
    /// (one column per scalar attribute, types via `sqlite_mapping::
    /// sql_type`) ; the db path is that hecksagon's `db:` option. Every
    /// other aggregate keeps the heki/memory repository
    /// `boot_with_data_dir` built. A no-op when no `:sqlite` hecksagon is
    /// attached.
    ///
    /// i735 — previously this OVER-APPLIED : any one `:sqlite` hecksagon
    /// rebuilt EVERY aggregate in a combined multi-domain root on SQL,
    /// panicking the whole bus when an unrelated aggregate carried
    /// SQL-incompatible columns. Scoping by context confines `:sqlite` to
    /// its own declaring domain, so it is safe to declare anywhere.
    #[cfg(not(target_arch = "wasm32"))]
    pub(super) fn apply_sqlite_persistence(&mut self) {
        // context → db_path for every hecksagon that wired :sqlite.
        let sqlite_dbs: HashMap<String, String> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.as_deref() == Some("sqlite"))
            .filter_map(|hex| {
                // parse_options keeps the raw token (quotes included) ;
                // strip the surrounding quotes to get the bare path.
                hex.persistence_option("db")
                    .map(|db| (hex.name.clone(), db.trim_matches('"').to_string()))
            })
            .collect();
        if sqlite_dbs.is_empty() {
            return;
        }
        // Collect patches under the immutable borrow of self.domain, then
        // apply them under the mutable borrow of self.repositories — the
        // two borrows cannot overlap through &mut self.
        let patches: Vec<(String, lazy_repository::SqliteConfig)> = self
            .domain
            .aggregates
            .iter()
            .filter_map(|agg| {
                let db_path = agg.context.as_deref().and_then(|ctx| sqlite_dbs.get(ctx))?;
                let mut columns: Vec<(String, String)> = agg
                    .attributes
                    .iter()
                    // Exclude the auto-managed columns `create_table` always
                    // adds itself : `id TEXT PRIMARY KEY`, `created_at`,
                    // `updated_at`. Every aggregate carries an `id` attribute
                    // (its identity) ; including it here produced a "duplicate
                    // column name: id" CREATE TABLE failure — latent under the
                    // old lazy path, surfaced now that construction is eager.
                    .filter(|a| {
                        !a.list
                            && !matches!(a.name.as_str(), "id" | "created_at" | "updated_at")
                    })
                    .map(|a| (a.name.clone(), sqlite_mapping::sql_type(&a.attr_type).to_string()))
                    .collect();
                // The lifecycle state field (e.g. `status`) is set on the
                // AggregateState at dispatch but is not a declared
                // attribute ; the typed-columns backend needs a TEXT
                // column for it or a cold query filtering on it reads
                // back nothing.
                if let Some(lc) = &agg.lifecycle {
                    columns.push((lc.field.clone(), "TEXT".to_string()));
                }
                let key = repo_key(agg.context.as_deref(), &agg.name);
                Some((
                    key,
                    lazy_repository::SqliteConfig {
                        aggregate_type: agg.name.clone(),
                        db_path: db_path.clone(),
                        identified_by: agg.identified_by.clone(),
                        columns,
                    },
                ))
            })
            .collect();
        for (key, config) in patches {
            // EAGER construction (i735 defect 2) : open + CREATE TABLE +
            // row-load happen now, at boot, because they are FALLIBLE.
            match sqlite_repository::SqliteRepository::new(
                &config.aggregate_type,
                &config.db_path,
                config.identified_by.clone(),
                config.columns.clone(),
            ) {
                Ok(repo) => {
                    self.repositories
                        .insert(key, LazyRepository::new_sqlite(repo));
                }
                Err(e) => {
                    // Never panic the bus ; never silently fall back to heki.
                    // Refuse THIS aggregate LOUDLY : drop its repository so no
                    // heki repo survives to be silently swapped in, and record
                    // the reason. The boot log names it now ; a dispatch
                    // against it returns a loud PersistenceRefused error.
                    let reason = format!(
                        "{key} : sqlite persistence refused — open/CREATE TABLE failed for db `{}`: {e}",
                        config.db_path
                    );
                    eprintln!("[persistence] {reason}");
                    self.repositories.remove(&key);
                    self.refused_persistence.insert(key, reason);
                }
            }
        }
    }

    /// Sweep every Repository and reload it from disk if its heki
    /// file has been written by a sibling process since our last
    /// load or save. The kernel-floor implementation of the
    /// `RefreshOnPulse` policy declared in
    /// runtime/storage/storage.bluebook : LoopDriver calls this at
    /// the start of every tick so a long-running daemon's in-memory
    /// store stays current with writes from sibling processes
    /// (e.g. `storehouse sleep` dispatching EnterSleep against a
    /// heki the run-loop daemon will read on its next tick).
    ///
    /// **Opt-in via `HECKS_REFRESH_REPOS=1`** — refresh is off by
    /// default. Production daemons (mindstream / long-running
    /// run-loops) set the env var to pick up cross-process state.
    /// Single-process smoke tests and one-shot dispatches leave it
    /// off so refresh doesn't interact with their in-memory cascade
    /// state (e.g. by re-reading partially-written counter-minted
    /// records and mid-cascade breaking singleton fallback ; see
    /// dream_content_smoke flakiness 2026-05-09).
    ///
    /// Cost when on : one stat() per repo per tick when nothing
    /// changed ; per-repo refresh_from_heki gates the actual read
    /// on mtime advance.
    /// Cost when off : zero — the function returns immediately.
    /// Closes the i517 root cause for the production-daemon path.
    pub fn refresh_repositories_from_heki(&mut self) {
        if std::env::var("HECKS_REFRESH_REPOS").ok().as_deref() != Some("1") {
            return;
        }
        for repo in self.repositories.values_mut() {
            repo.refresh_from_heki();
        }
    }

    /// Warm-serve freshness sweep — refresh ONLY the repos already
    /// hydrated in this resident process. Sibling to
    /// `refresh_repositories_from_heki`, with two deliberate
    /// differences that make it the right primitive for `serve` mode :
    ///
    ///   1. **No env gate.** `serve` calls this unconditionally before
    ///      every dispatch. The `HECKS_REFRESH_REPOS=1` guard on the
    ///      sibling exists to keep one-shot CLI dispatches and in-memory
    ///      smoke tests from re-reading mid-cascade ; a resident server
    ///      that answers from a warm runtime must ALWAYS reconcile with
    ///      disk first, because daemons (heart/breath) write `.heki`
    ///      concurrently between requests.
    ///
    ///   2. **Hydrated-only.** `LazyRepository::refresh_from_heki` forces
    ///      `repo_mut()` → `get_or_init` → hydration. Sweeping ALL repos
    ///      would hydrate every aggregate on the first request and throw
    ///      away the lazy-boot win this whole feature is built on. We
    ///      filter on `is_hydrated()` : a repo that's never been touched
    ///      stays cold (and, when it IS first touched by a later
    ///      dispatch, the OnceCell init reads current disk by
    ///      definition — so cold repos are fresh for free). Only the
    ///      handful of repos this process has actually served pay the
    ///      one `stat()` per request ; the mtime gate inside
    ///      `refresh_from_heki` skips the re-read when disk is unchanged.
    ///
    /// This is THE correctness crux of warm serve : the IR stays warm
    /// (the boot is paid once) but the touched aggregate's STATE is
    /// never stale.
    pub fn refresh_hydrated_repositories_from_heki(&mut self) {
        for repo in self.repositories.values_mut() {
            if repo.is_hydrated() {
                repo.refresh_from_heki();
            }
        }
    }

    /// Rebuild on the explicit `Backend::Memory` ONLY those aggregates whose
    /// governing hecksagon declares `:memory` — matched by `agg.context ==
    /// hecksagon.name`, the same per-context scoping as
    /// `apply_sqlite_persistence`. Until this ran, `:memory` was INERT : a
    /// declared-`:memory` aggregate fell through to the implicit heki default
    /// `boot_with_data_dir` built, so `:memory` and `unwired` were
    /// indistinguishable on disk. Now `:memory` actually selects in-process
    /// memory — the keystone for "tests get memory, production fails loud on
    /// unwired". Every other aggregate keeps its heki repository. A no-op when
    /// no `:memory` hecksagon is attached. Memory is host- AND wasm-valid, so
    /// — unlike `apply_sqlite_persistence` — this carries no cfg gate.
    pub(super) fn apply_memory_persistence(&mut self) {
        let memory_contexts: std::collections::HashSet<&str> = self
            .hecksagons
            .iter()
            .filter(|hex| hex.persistence.as_deref() == Some("memory"))
            .map(|hex| hex.name.as_str())
            .collect();
        if memory_contexts.is_empty() {
            return;
        }
        // Collect patches under the immutable borrow of self.domain, then apply
        // them under the mutable borrow of self.repositories — mirrors
        // apply_sqlite_persistence's two-phase borrow discipline.
        let patches: Vec<(String, String, Option<String>, Option<String>)> = self
            .domain
            .aggregates
            .iter()
            .filter(|agg| {
                agg.context
                    .as_deref()
                    .map_or(false, |ctx| memory_contexts.contains(ctx))
            })
            .map(|agg| {
                (
                    repo_key(agg.context.as_deref(), &agg.name),
                    agg.name.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                )
            })
            .collect();
        for (key, name, identified_by, context) in patches {
            self.repositories
                .insert(key, LazyRepository::new_memory(&name, identified_by, context));
        }
    }
    /// Bucket-3 step 4 — the hexagon-binding CONSULT. Where
    /// `apply_memory_persistence` / `apply_sqlite_persistence` read the LEGACY
    /// `.hecksagon` persistence block (`hex.persistence`), this reads the NEW
    /// port-verb binding surface — `Pizzas::Order.persisted_by("Heki")` — that
    /// steps 1-3 parse + resolve. It runs `resolve_bindings` over the loaded IR
    /// and, for every bind that resolves on the `persistence` family, rebuilds
    /// that aggregate's repository on the backend its adapter NAMES — so the
    /// runtime OBEYS the declaration rather than coinciding with the heki
    /// default. Additive : an aggregate with no persistence binding keeps the
    /// repository `boot_with_data_dir` built. Runs AFTER apply_memory /
    /// apply_sqlite, so where an aggregate ever carried BOTH a legacy block and
    /// a binding the binding (the new surface) is last-writer ; no corpus
    /// aggregate carries both today.
    ///
    /// adapter-name → backend : "Heki" rebuilds heki at the runtime `data_dir`
    /// — the SAME constructor `boot_with_data_dir` uses, so it is byte-identical
    /// to the default, now binding-driven ; "Memory" selects the explicit
    /// in-process `Backend::Memory` (the discriminating case that proves the
    /// consult bites). Sqlite via the binding surface is not exercised —
    /// `adapter :sqlite, db:` still routes through `apply_sqlite_persistence`'s
    /// legacy block (fallible, db-path-carrying), so an unrecognised
    /// persistence-family adapter leaves the default repo untouched. Ungated :
    /// like memory, the heki/memory constructors are host- AND wasm-valid.
    pub(super) fn apply_hexagon_persistence(&mut self) {
        use super::hexagon_resolution::{resolve_bindings, ResolveOutcome};
        // (aggregate FQN, adapter) for every bind resolving on the persistence
        // family. resolve_bindings already type-checked the adapter->family->verb
        // attach ; an unresolved bind never reaches here.
        let binds: Vec<(String, String)> = resolve_bindings(&self.hecksagons)
            .into_iter()
            .filter_map(|r| match r.outcome {
                ResolveOutcome::Resolved { family } if family == "persistence" => {
                    Some((r.aggregate, r.adapter))
                }
                _ => None,
            })
            .collect();
        if binds.is_empty() {
            return;
        }
        let data_dir = self.data_dir.clone();
        // Resolve each bound FQN to its repo_key + ctor params under the
        // immutable borrow ; patch under the mutable borrow — the two-phase
        // discipline apply_memory_persistence uses. The bind's aggregate IS the
        // FQN, which equals `repo_key(context, name)`.
        let patches: Vec<(String, String, Option<String>, Option<String>, String)> = self
            .domain
            .aggregates
            .iter()
            .filter_map(|agg| {
                let key = repo_key(agg.context.as_deref(), &agg.name);
                binds.iter().find(|(fqn, _)| *fqn == key).map(|(_, adapter)| {
                    (
                        key.clone(),
                        agg.name.clone(),
                        agg.identified_by.clone(),
                        agg.context.clone(),
                        adapter.clone(),
                    )
                })
            })
            .collect();
        for (key, name, identified_by, context, adapter) in patches {
            let repo = match adapter.as_str() {
                "Memory" => LazyRepository::new_memory(&name, identified_by, context),
                "Heki" => LazyRepository::new(&name, data_dir.clone(), identified_by, context),
                // A persistence-family adapter the consult does not mint (e.g. a
                // future Sqlite binding) leaves the default repo in place.
                _ => continue,
            };
            self.repositories.insert(key, repo);
        }
    }}
