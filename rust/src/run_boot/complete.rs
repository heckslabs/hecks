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
//! policy before the dispatch returns. The authz roster (Phase 4) establishes
//! through this path ; every future establishment policy rides it.
//!
//! ## FINDING-keystone-dead-path (2026-07-03) — how it was still dead, fixed here
//!
//!   * The real boot.bluebook gates `CompleteBoot` behind `from: "completing"`
//!    and this runtime's BootRun is a FRESH singleton (persisted_by :memory),
//!    so the dispatch died as a `LifecycleViolation` that `let _ =` swallowed —
//!    verified live : boot green, store untouched. [`stage_pipeline_settled`]
//!    now stages the singleton at the from-state the transition requires (the
//!    native phase walk HAS settled by the time completion is routed — the
//!    runtime telling the domain the truth about where the pipeline stands),
//!    and a rejected dispatch is LOUD, never silent.
//!   * Completion was reachable only from inside the boot runner. [`establish`]
//!    exposes it as the `storehouse establish <root>` verb — a mindstream
//!    member can run it after boot, and the roster can be re-asserted on
//!    demand (idempotent : establishment targets upsert on natural keys).
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
use crate::runtime::{AggregateState, Runtime, Value};

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

/// Stage the completion runtime's fresh BootRun singleton at the lifecycle
/// from-state its `CompleteBoot` transition requires (`"completing"` in the
/// real boot.bluebook). This runtime is a RE-ENTRY : the native phase walk
/// already ran (in the runner's own runtime, or out-of-process entirely for
/// `storehouse establish`), but BootRun persists to :memory, so here it would
/// boot at the lifecycle default (`"pending"`) and `CompleteBoot` would be
/// rejected as a LifecycleViolation — the silent keystone dead path. The
/// domain doesn't know it hibernates ; presenting the aggregate where the
/// pipeline truly stands is the runtime's job. No-op when the boot domain
/// declares no such transition (the tests' minimal inline BOOT domain).
///
/// The singleton id "1" matches what the dispatch will mint : BootRun carries
/// no `identified_by`, so `id_for_command` counter-mints from 1, and `save`
/// never advances the counter.
fn stage_pipeline_settled(rt: &mut Runtime) {
    let staged = rt.domain.aggregates.iter()
        .filter(|a| a.name == "BootRun")
        .find_map(|a| a.lifecycle.as_ref().and_then(|lc| {
            lc.transitions.iter()
                .find(|t| t.command == "CompleteBoot")
                .and_then(|t| t.from_state.clone())
                .map(|from| (lc.field.clone(), from))
        }));
    let Some((field, from)) = staged else { return };
    let Some(key) = crate::runtime::repo_lookup_key(&rt.repositories, "BootRun") else { return };
    let Some(repo) = rt.repositories.get_mut(&key) else { return };
    let mut state = AggregateState::new("1");
    state.set(&field, Value::Str(from));
    repo.save(state, crate::heki::WriteContext::OutOfBand {
        reason: "boot completion — stage the fresh BootRun singleton at the phase the \
                 native pipeline already reached, so CompleteBoot passes its lifecycle \
                 gate (FINDING-keystone-dead-path)",
    });
}

/// Inner, testable : merge boot into corpus, boot the runtime, dispatch
/// `CompleteBoot` so `BootCompleted` emits and `drain_policies` fans out to
/// every registered `on "BootCompleted"` establishment policy. Returns the
/// settled runtime for inspection (the cascade is synchronous — complete when
/// this returns). Prefer [`complete_over_checked`] when the caller must know
/// whether completion actually routed.
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
    complete_over_checked(boot_domain, corpus_domain, data_dir, hecksagons, aggregates_root, being).0
}

/// [`complete_over`] that ALSO reports whether `CompleteBoot` actually
/// dispatched. The old `let _ = rt.dispatch(…)` is exactly how the keystone
/// dead path stayed silent (FINDING-keystone-dead-path) — callers on the live
/// path print the error ; `storehouse establish` exits nonzero on it.
pub fn complete_over_checked(
    boot_domain: Domain,
    corpus_domain: Domain,
    data_dir: Option<String>,
    hecksagons: Vec<Hecksagon>,
    aggregates_root: Option<String>,
    being: &str,
) -> (Runtime, Result<(), String>) {
    let merged = merge_boot_into_corpus(corpus_domain, boot_domain);
    let mut rt = Runtime::boot_with_hecksagons(merged, data_dir, hecksagons);
    rt.aggregates_root = aggregates_root;
    stage_pipeline_settled(&mut rt);
    let mut attrs = HashMap::new();
    attrs.insert("being".to_string(), Value::Str(being.to_string()));
    // Aggregate-qualified so the command resolves unambiguously in the full
    // corpus (BootRun is corpus-unique). The outcome is REPORTED, never a
    // panic : boot already succeeded ; the establishment cascade is a
    // post-completion effect, never a gate on the boot exit code.
    let outcome = rt.dispatch("BootRun.CompleteBoot", attrs).map(|_| ()).map_err(|e| {
        format!(
            "BootRun.CompleteBoot was rejected ({e:?}) — BootCompleted never emitted, \
             establishment policies did NOT fire"
        )
    });
    // The establishment cascade may have authored RoleAssignments (the authz
    // roster). Those arrive as CASCADES, so the entry-dispatch re-hydrate
    // trigger in `Runtime::dispatch` never fires for them (the entry aggregate
    // is BootRun, not RoleAssignment) — re-hydrate the RBAC read-model now
    // that the cascade has settled, so THIS runtime (and any boot assertion
    // inspecting it) sees the roster immediately. Later runtimes hydrate at
    // their own boot from persisted state.
    rt.rehydrate_acl();
    (rt, outcome)
}

/// Outer : resolve the LIVE corpus + persistence dir + conception root, then
/// dispatch `CompleteBoot` on the corpus-loaded runtime. `boot_domain` and
/// `hecksagons` are cloned from the runner's already-booted runtime (no
/// re-parse, no second bluebook read). Failures are LOUD (stderr) but never
/// gate the boot exit code — `storehouse establish <root>` is the re-runnable,
/// exit-code-honest form.
///
/// Descoped (Chris, keystone review) : the completion runtime carries only the
/// boot hecksagons, not the whole corpus's — establishment POLICIES register
/// and fire without any hecksagon, and zero establishment EFFECTS (which would
/// need a corpus adapter) exist today. Lifting the cli-only `load_all_hecksagons`
/// into `corpus_loader` so the completion runtime wires every adapter is a
/// separate follow-up.
pub fn complete_boot(boot_domain: Domain, hecksagons: Vec<Hecksagon>, being: &str) {
    let root = crate::storehouse_router::conception_root();
    let corpus = load_combined_domain(&root);
    // Persist establishment writes to the same world heki dir the dispatch
    // door resolves. Establishment policies EXIST now (the authz roster), so
    // `None` means their writes would be silently discarded with the
    // in-memory runtime — a loud misconfiguration, not a safe default (the
    // old "safe today since nothing establishes" era ended with the roster).
    let data_dir = crate::heki::resolve_world_store_dir(&root);
    if data_dir.is_none() {
        eprintln!(
            "[boot-completion] no world store resolves for {root} — establishment \
             writes will NOT persist (completion runtime is memory-only). Declare \
             `dir :default` in a `heki` block of a .world under the root."
        );
    }
    let (_, outcome) =
        complete_over_checked(boot_domain, corpus, data_dir, hecksagons, Some(root), being);
    if let Err(e) = outcome {
        eprintln!("[boot-completion] {e}");
    }
}

/// `storehouse establish <root>` — the keystone as a first-class verb
/// (FINDING-keystone-dead-path, Option A). Load the corpus at `root`, merge
/// the boot domain in, route `BootCompleted` through the corpus-loaded policy
/// engine, and PERSIST the establishment writes to the root's world store.
/// Idempotent : establishment targets upsert on natural keys (the roster
/// re-asserts, never duplicates), so re-running — or racing the boot member —
/// is safe. Returns the process exit code : 0 established, 1 failed.
pub fn establish(root: &str, boot_domain: Domain, hecksagons: Vec<Hecksagon>, being: &str) -> i32 {
    let corpus = load_combined_domain(root);
    // No store = nothing persists = the verb would be theatre. Refuse loudly
    // instead of "succeeding" in memory.
    let Some(data_dir) = crate::heki::resolve_world_store_dir(root) else {
        eprintln!(
            "storehouse establish: no world store resolves for {root} — establishment \
             writes would not persist. Declare `dir :default` in a `heki` block of a \
             .world under the root."
        );
        return 1;
    };
    let root_abs = std::fs::canonicalize(root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| root.to_string());
    let (rt, outcome) =
        complete_over_checked(boot_domain, corpus, Some(data_dir.clone()), hecksagons, Some(root_abs), being);
    match outcome {
        Ok(()) => {
            println!(
                "established: BootCompleted routed through the corpus policy engine · \
                 {} role assignments · {} policies (store: {})",
                rt.all("RoleAssignment").len(),
                rt.all("Policy").len(),
                data_dir
            );
            0
        }
        Err(e) => {
            eprintln!("storehouse establish: {e}");
            1
        }
    }
}
