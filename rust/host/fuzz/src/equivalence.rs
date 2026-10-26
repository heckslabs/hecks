//! Plays a script and compares the stores.
//!
//! Every script runs against the in-memory store first. That run checks, by itself, what any store
//! must do: an accepted command pairs the snapshot with the newest journal row, and a refused or
//! failed one changes nothing. A script then reaches Postgres only if its footprint is due (see
//! [`crate::footprint`]), and a difference between the two runs is confirmed once more before it is
//! reported, since the host stamps the wall clock into the arguments a command `needs`.
//!
//! Postgres is the point of the comparison: a pass on the in-memory store alone cannot see a
//! difference between the stores, which is why a footprint seen for the first time always goes on.

use crate::backend::{Backend, MemoryBackend, Observed, PostgresBackend, Step};
use crate::footprint::{self, Memo};
use crate::ops::Script;
use std::sync::atomic::Ordering;
use std::sync::OnceLock;
use tokio::runtime::{Builder, Runtime};

/// The libpq-style connection string of the scratch database. Unset, only the in-memory store runs.
pub const POSTGRES_ENV: &str = "HECKS_FUZZ_PG";

/// How often, in executions, the run says how much it skipped.
const REPORT_EVERY: u64 = 1 << 14;

/// What one script left behind in one store.
#[derive(Debug, Clone, PartialEq)]
struct Trace {
    steps: Vec<Step>,
    observed: Observed,
}

/// Everything that outlives one input: the runtime, both stores, the memo. Built on first use and
/// reused for the rest of the campaign.
struct Rig {
    runtime: Runtime,
    memory: MemoryBackend,
    postgres: Option<PostgresBackend>,
    memo: Memo,
}

static RIG: OnceLock<Rig> = OnceLock::new();
static EXECS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn rig() -> &'static Rig {
    RIG.get_or_init(|| {
        // One thread: libFuzzer calls the target from one, and a current-thread runtime adds no
        // scheduler for the sanitizer to track.
        let runtime = Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("a current-thread runtime builds");
        let postgres = std::env::var(POSTGRES_ENV)
            .ok()
            .filter(|v| !v.is_empty())
            .map(|conninfo| {
                runtime
                    .block_on(PostgresBackend::connect(&conninfo))
                    .unwrap_or_else(|e| {
                        panic!("{POSTGRES_ENV} is set but the store is unusable: {e:#}")
                    })
            });
        Rig {
            runtime,
            memory: MemoryBackend::new(),
            postgres,
            memo: Memo::default(),
        }
    })
}

/// Runs `script` from an empty store. With `clause` set, the store is read around every step and the
/// commit clause is asserted, which costs two reads a step; only the cheap store pays for that.
async fn play<B: Backend>(backend: &B, script: &Script, clause: bool) -> Trace {
    backend.reset().await.expect("the store resets");
    let mut steps = Vec::with_capacity(script.ops.len());
    for (verb, args) in script.steps() {
        let before = if clause {
            Some(backend.observe().await.expect("the store reads"))
        } else {
            None
        };
        let step = backend.dispatch(verb, args).await;
        if let Some(before) = before {
            let after = backend.observe().await.expect("the store reads");
            assert_commit_clause(&step, &before, &after, steps.len());
        }
        steps.push(step);
    }
    Trace {
        steps,
        observed: backend.observe().await.expect("the store reads"),
    }
}

/// An accepted command pairs the snapshot with one more journal row; any other leaves the store as
/// it was (the commit clause the host's conformance suite pins on a fixed script).
fn assert_commit_clause(step: &Step, before: &Observed, after: &Observed, at: usize) {
    if step.accepted() {
        let grew = after.snapshot_ordinal.unwrap_or(0) - before.snapshot_ordinal.unwrap_or(0);
        assert_eq!(
            grew, 1,
            "step {at}: an accepted command advances the snapshot by one row"
        );
    } else {
        assert_eq!(
            after, before,
            "step {at}: a {step:?} command changed the store"
        );
    }
}

fn disagreement(memory: &Trace, postgres: &Trace) -> String {
    format!("memory and postgres disagree\n memory:   {memory:#?}\n postgres: {postgres:#?}")
}

/// Builds the rig and compiles the kernel, for libFuzzer's initialization hook, which its per-input
/// timeout does not cover. Compiling the module under a sanitizer takes longer than that timeout,
/// so the first input would otherwise be reported as a hang.
///
/// # Panics
///
/// When the kernel is missing or does not compile, or `HECKS_FUZZ_PG` names a store that is unusable.
pub fn warm() {
    let _ = rig();
    rust_host::wasm_runner::warm(&crate::backend::wasm_path())
        .unwrap_or_else(|e| panic!("the kernel does not compile: {e:#}"));
}

/// What `check` did with one script, for a caller that wants to know.
#[derive(Debug, Clone, Copy, Default)]
pub struct Summary {
    pub steps: usize,
    pub accepted: usize,
    /// Whether Postgres was asked, which is false when it is off or its footprint was already agreed.
    pub compared: bool,
}

/// Plays `script` against the in-memory store, and against Postgres when its footprint is due.
///
/// # Panics
///
/// On an invariant the in-memory run breaks, or a difference between the stores that a second run
/// reproduces. libFuzzer keeps the input that panicked.
pub fn check(script: &Script) -> Summary {
    let rig = rig();
    let summary = rig.runtime.block_on(async {
        let memory = play(&rig.memory, script, true).await;
        let accepted: Vec<bool> = memory.steps.iter().map(Step::accepted).collect();
        let mut summary = Summary {
            steps: accepted.len(),
            accepted: accepted.iter().filter(|a| **a).count(),
            compared: false,
        };
        let Some(postgres) = &rig.postgres else {
            return summary;
        };
        let print = footprint::of(script, &accepted);
        if !rig.memo.due(print) {
            return summary;
        }
        summary.compared = true;
        let theirs = play(postgres, script, false).await;
        if theirs != memory {
            let again_memory = play(&rig.memory, script, false).await;
            let again_postgres = play(postgres, script, false).await;
            assert_eq!(
                again_memory,
                again_postgres,
                "{}",
                disagreement(&again_memory, &again_postgres)
            );
        }
        rig.memo.agreed(print);
        summary
    });
    report(rig);
    summary
}

fn report(rig: &Rig) {
    let execs = EXECS.fetch_add(1, Ordering::Relaxed) + 1;
    if execs % REPORT_EVERY == 0 && rig.postgres.is_some() {
        eprintln!(
            "[equivalence] {execs} scripts: {} verified on postgres, {} skipped as already agreed",
            rig.memo.verified.load(Ordering::Relaxed),
            rig.memo.skipped.load(Ordering::Relaxed),
        );
    }
}
