//! Supervisor — per-actor failure isolation helpers
//!
//! When a mailbox handler panics, `std::panic::catch_unwind` (run
//! inside each spawn_blocking task) catches the unwind. The
//! supervisor's job here is just to translate the panic payload into
//! a stringly reason and report the outcome up to the registry's
//! drain loop. The registry uses `SupervisorOutcome` to decide
//! whether to count this mailbox as poisoned in the `DrainSummary` —
//! letting tests assert "one mailbox crashed, the other N continued."
//!
//! Tokio teardown : panics that ESCAPE the inner catch_unwind surface
//! as `JoinError::is_panic()` when the JoinSet awaits the task. The
//! registry's drain loop catches that path too, falling back through
//! `stringify_panic` on the panic payload extracted from the JoinError.
//! No explicit CancellationToken is required because the JoinSet is
//! drained to completion in the same scope ; dropping the registry
//! drops the JoinSet which aborts any tasks still in flight.
//!
//! No retry. No replay. A panicked mailbox is poisoned ; new
//! envelopes still enqueue (audit trail) but the handler is never
//! re-invoked on this mailbox. Per Chris-standards : never silently
//! retry a fail. Recovery is a NEW command, not a re-run.
//!
//! Usage :
//!   let outcome = catch_unwind_inside_drain();
//!   match outcome {
//!       SupervisorOutcome::Drained(n) => /* normal */,
//!       SupervisorOutcome::Poisoned(reason) => /* one mailbox lost */,
//!   }

use std::any::Any;

#[derive(Debug, Clone)]
pub enum SupervisorOutcome {
    /// Drain completed without panic ; carries the count of envelopes
    /// successfully handled.
    Drained(usize),
    /// A handler panicked ; carries the panic message extracted from
    /// the payload. The mailbox has been marked Poisoned and no
    /// further handler invocations will occur on it.
    Poisoned(String),
}

/// Best-effort extraction of a human-readable reason from a panic
/// payload. The payload is `Box<dyn Any + Send>` ; `panic!("x")`
/// produces a `&'static str` while `panic!("{}", x)` produces a
/// `String`. We handle both, falling back to a stub for non-string
/// payloads.
pub fn stringify_panic(p: &Box<dyn Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        return (*s).to_string();
    }
    if let Some(s) = p.downcast_ref::<String>() {
        return s.clone();
    }
    "unknown panic payload".to_string()
}
