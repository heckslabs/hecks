//! The `ValueObject`/`OneOf` constructs
//! (`lib/hecksagain/bluebook/ir/value_object.rb`) — shared here exactly as
//! `ValueObjectBuilder` answers both in Ruby (`one_of` `instance_eval`s
//! its block on the builder itself, so the two contexts are one Ruby
//! object; see `spec/syntax_conformance_spec.rb`'s own `BUILDER` table).
//! Stage 2+ work: `invariant` source-body capture, and `member` rows
//! (`build/closed_sets.rs`) — an open map of pairs, captured verbatim per
//! `PairsShape::verbatim`.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ValueObject.{word}"))
}
