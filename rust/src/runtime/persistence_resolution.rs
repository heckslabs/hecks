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
}
