//! The `Aggregate` construct (`lib/hecksagain/bluebook/ir/aggregate.rb`,
//! built by `Hecksagain::Bluebook::DSL::AggregateBuilder`). Stage 2+ work:
//! `identified_by`'s three forms (block/bare-field/bare-type — see
//! `attribute_collector.rb`'s `resolve_identity_field!`/
//! `resolve_identity_type!`), `reference_to`/`has_many`/`has_one`/
//! `belongs_to` attribute-minting, `value_object`/`one_of` closed-set
//! synthesis, and folding a nested `lifecycle` block onto this record —
//! each mirrored in `build/identity.rs`, `build/references.rs`,
//! `build/closed_sets.rs` respectively, once those stop being stubs.
//!
//! Stage 1: reached only when `parse::walk_body` has already gated (for
//! real) the `aggregate "Name" do` header AND every line of its own body,
//! recursing through nested `do` blocks the identical way — this stub is
//! the honest admission that none of it is built into `ir::Aggregate` yet.

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Aggregate.{word}"))
}
