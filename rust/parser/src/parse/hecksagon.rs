//! The `Hecksagon` construct (`lib/hecksagain/language/hecksagon.bluebook`,
//! `HecksagonBuilder`) — a `.hecksagon` file's own content: `binds`,
//! `subscriptions`, `framework_members` (`uses_framework`). Two things
//! contribute to `ir.json` per the plan's finding #5: `port ... do ... end`
//! blocks (`add_port`) and `uses_framework` (which OTHER chapters get
//! generated) — everything else (`persisted_by`, `projected_by`,
//! `subscribe`) is accepted and ignored, not built.
//!
//! The `.hecksagon` adapter-bind shape itself (`Aggregate.persisted_by(...)`,
//! `Const.verb(...)`) is one of the plan's two narrow, permanent
//! open-vocabulary escapes — shape-matched and its contents DROPPED, never
//! interpreted. Not yet implemented even as a drop at Stage 1 (see
//! parse/mod.rs's `dispatch_stub` comment on `World` for the matching
//! gap) — named here as tracked Stage 2+ work rather than guessed at.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Hecksagon.{word}"))
}
