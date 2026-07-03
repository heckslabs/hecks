//! run_boot/complete.rs — the boot-COMPLETION step : route `BootCompleted`
//! through the policy engine so cross-domain ESTABLISHMENT policies fire.
//!
//! [antibody-exempt: rust/src/run_boot/complete.rs — boot-pipeline completion
//!  module, same category + rationale as run_boot/mod.rs (Chris 2026-06-01) :
//!  imperative runner glue that mirrors the boot.bluebook pipeline and retires
//!  with it under i78/i145.]
//!
//! ## Why this exists (the boot-establishment keystone)
//!
//! Production standing-state (authorization permits, deny-by-default
//! governance, governed-door redirects) is meant to reach prod as self-seeding
//! POLICY that fires `on "BootCompleted"` — never as test fixtures. That was
//! dead for two reasons, both in the boot runner :
//!
//!   1. `run_boot::run` walks phases 1–8 as native Rust and never dispatches
//!      `CompleteBoot`, so `BootCompleted` never emitted at a real boot.
//!   2. The runner's runtime held only the single boot domain, so no
//!      cross-domain `on "BootCompleted"` policy was even registered.
//!
//! This module closes both : after the native phases settle, it boots ONE
//! runtime over the FULL corpus (the merged boot domain + every organ /
//! capability domain) and dispatches `CompleteBoot`. `BootCompleted` emits ;
//! the synchronous `drain_policies` fans out to every registered establishment
//! policy before the dispatch returns. Zero establishment policies exist today,
//! so this is LATENT-BUT-WIRED : nothing fires yet, but the moment an
//! `on "BootCompleted"` policy lands in the corpus it self-seeds at boot.
//!
//! The corpus is loaded ONCE, here, off the native hot path — the phase walk
//! stays single-domain and fast. Mirrors the corpus-boot pattern the cold
//! dispatch door (`dispatch_hecksagon`) already trusts : `load_combined_domain`
//! + `Runtime::boot_with_hecksagons` + dispatch.
//!
//! The inner [`complete_over`] takes explicit domains + data_dir so a test can
//! drive the real wiring in memory, with inline domains, never touching disk
//! or the real conception. The outer [`complete_boot`] resolves the live
//! corpus + persistence dir + conception root and calls it.

use crate::corpus_loader::load_combined_domain;
use crate::hecksagon_ir::Hecksagon;
use crate::ir::Domain;
use crate::runtime::{Runtime, Value};

use std::collections::HashMap;

/// Merge the boot domain INTO the corpus domain. Corpus wins on an aggregate
/// collision (organ-wins, mirroring `corpus_loader`'s `(context, name,
/// category)` dedupe) ; the boot domain's own aggregates (`BootRun` — declared
/// nowhere else, since the corpus walk never reaches `runtime/boot/`) and its
/// policies are appended, so `CompleteBoot` resolves and `StartStudioOnComplete`
/// registers. Policies / PMs / cadences / grammars extend, never dedupe — same
/// as the loader's merge.
fn merge_boot_into_corpus(mut corpus: Domain, boot: Domain) -> Domain {
    for agg in boot.aggregates {
        if corpus.aggregates.iter().any(|e| {
            e.name == agg.name && e.context == agg.context && e.category == agg.category
        }) {
            continue;
        }
        corpus.aggregates.push(agg);
    }
    corpus.policies.extend(boot.policies);
    corpus.process_managers.extend(boot.process_managers);
    corpus.cadences.extend(boot.cadences);
    corpus.block_grammars.extend(boot.block_grammars);
    corpus
}

/// Inner, testable : merge boot into corpus, boot the runtime, dispatch
/// `CompleteBoot` so `BootCompleted` emits and `drain_policies` fans out to
/// every registered `on "BootCompleted"` establishment policy. Returns the
/// settled runtime for inspection (the cascade is synchronous — complete when
/// this returns).
///
/// `aggregates_root` is set on the runtime BEFORE the dispatch so an
/// establishment cascade that re-enters via the out-of-process outbox has its
/// re-entry root (as the cold dispatch door sets it). Tests pass `None`.
pub fn complete_over(
    boot_domain: Domain,
    corpus_domain: Domain,
    data_dir: Option<String>,
    hecksagons: Vec<Hecksagon>,
    aggregates_root: Option<String>,
    being: &str,
) -> Runtime {
    let merged = merge_boot_into_corpus(corpus_domain, boot_domain);
    let mut rt = Runtime::boot_with_hecksagons(merged, data_dir, hecksagons);
    rt.aggregates_root = aggregates_root;
    let mut attrs = HashMap::new();
    attrs.insert("being".to_string(), Value::Str(being.to_string()));
    // Aggregate-qualified so the command resolves unambiguously in the full
    // corpus (BootRun is corpus-unique). The dispatch result is intentionally
    // ignored : boot already succeeded ; the establishment cascade is a
    // best-effort post-completion effect, never a gate on the boot exit code.
    let _ = rt.dispatch("BootRun.CompleteBoot", attrs);
    // The establishment cascade may have authored RoleAssignments (the authz
    // roster). Those arrive as CASCADES, so the entry-dispatch re-hydrate
    // trigger in `Runtime::dispatch` never fires for them (the entry aggregate
    // is BootRun, not RoleAssignment) — re-hydrate the RBAC read-model now
    // that the cascade has settled, so THIS runtime (and any boot assertion
    // inspecting it) sees the roster immediately. Later runtimes hydrate at
    // their own boot from persisted state.
    rt.rehydrate_acl();
    rt
}

/// Outer : resolve the LIVE corpus + persistence dir + conception root, then
/// dispatch `CompleteBoot` on the corpus-loaded runtime. `boot_domain` and
/// `hecksagons` are cloned from the runner's already-booted runtime (no
/// re-parse, no second bluebook read).
///
/// Descoped (Chris, keystone review) : the completion runtime carries only the
/// boot hecksagons, not the whole corpus's — establishment POLICIES register
/// and fire without any hecksagon, and zero establishment EFFECTS (which would
/// need a corpus adapter) exist today. Lifting the cli-only `load_all_hecksagons`
/// into `corpus_loader` so the completion runtime wires every adapter is a
/// separate follow-up.
pub(crate) fn complete_boot(boot_domain: Domain, hecksagons: Vec<Hecksagon>, being: &str) {
    let root = crate::storehouse_router::conception_root();
    let corpus = load_combined_domain(&root);
    // Persist establishment writes to the same world heki dir the boot runtime
    // uses. `None` (no world store) boots the completion runtime in memory —
    // safe today since nothing establishes.
    let data_dir = crate::heki::resolve_world_store_dir(&root);
    let _ = complete_over(boot_domain, corpus, data_dir, hecksagons, Some(root), being);
}
