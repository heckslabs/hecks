//! The `Lifecycle` construct (`lib/hecksagain/bluebook/ir/lifecycle.rb`).
//! NOT a category of its own in `syntax.bluebook`'s `Keyword.opens` column
//! — it's a DECLARED FOLD onto whichever of `Aggregate`/`Entity` opened it
//! (`lifecycle`'s own row: `opens: ""`, `fills: "state_field"`); Stage 2+
//! folding logic has to land the built `Lifecycle` on the ENCLOSING
//! record rather than treat it as independent. `parse::walk_body` still
//! recurses into `Lifecycle` context the same way any other `do`-body
//! does — real gating for every `transition` line inside — and reports
//! this module's own stub once that's done, since Stage 1 builds nothing
//! regardless of which record a construct eventually folds onto.
//! Stage 2+ work: `transition ... from: [...]` list expansion (see the
//! Ruby source's own `expand`).

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Lifecycle.{word}"))
}
