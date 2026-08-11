//! The `ProcessManager`/`Handler` constructs
//! (`lib/hecksagain/bluebook/ir/process_manager.rb`) — shared here the
//! same way Ruby shares them (`Handler`'s builder is
//! `ProcessManagerBuilder::HandlerBuilder`, a nested class, not a
//! standalone one — see `spec/syntax_conformance_spec.rb`'s `BUILDER`
//! table). Stage 2+ work: `on ... do |event| dispatch ... end` handler
//! bodies, the `transition:`/`from_state`/`to_state` pairs-fields shape,
//! and the derived (never author-typed) `saga`/`Saga` compensation
//! reading — `handler_for("refused")`, deliberately absent from `to_h`.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ProcessManager.{word}"))
}
