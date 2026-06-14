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
}
