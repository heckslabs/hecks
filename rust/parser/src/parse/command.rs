//! The `Command` construct (`lib/hecksagain/bluebook/ir/command.rb`) — a
//! verb declared on an aggregate or entity. Stage 2+ work: `given`/
//! `ensures` source-body capture through canonical.rs, `sets`' four named
//! forms (`to`/`append`/`increment`/`decrement`, the op-selection column
//! `Argument#selects` names), and `emits` list capture.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Command.{word}"))
}
