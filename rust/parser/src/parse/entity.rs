//! The `Entity` construct (`lib/hecksagain/bluebook/ir/entity.rb`, built
//! by `Hecksagain::Bluebook::DSL::EntityBuilder`) — a piece of an
//! aggregate with an identity of its own. Stage 2+ mirrors
//! `AggregateBuilder`'s own `identified_by` handling line for line (the
//! same `AttributeCollector` module both builders include), minus the
//! words an entity doesn't admit (no `value_object`, no `policy`, no
//! nested `entity` — see syntax.bluebook's own comment on why a piece
//! says less than a head).

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Entity.{word}"))
}
