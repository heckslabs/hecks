//! validator_mutations.rs — the per-command mutation-wellformedness check.
//!
//! A `then_set` naming an unknown op (`then_set :items, bogus_op: {…}`) is
//! recorded by the parser as a Mutation with `invalid_op = Some("bogus_op")`
//! rather than panicking — a crash on a typo'd bluebook aborts every reader
//! (CLI validate, dispatch, behaviors) with a Rust stack trace, the worst
//! first-contact a newcomer can hit (DX perfection game, Tier 0 #2). This
//! rule turns that recorded fact into a graceful INVALID at validate time,
//! carrying the same valid-op hint the old panic did.
//!
//! Per-command + per-file : an unknown op is wrong regardless of corpus, so
//! this runs UNCONDITIONALLY in every `validate` path (bare, batch, corpus) —
//! unlike the reference checks, it has no corpus-vs-single-file distinction.
//!
//! The runtime carries its own guard (`interpreter::check_givens` refuses to
//! dispatch a command with an invalid-op mutation) so a caller that skips
//! validation still cannot silently apply the placeholder `Set`. This rule is
//! the author-facing half ; that guard is the runtime half.
//!
//! Hand-written framework source — outside the specializer targets
//! (validator.rs / validator_warnings.rs), the same home as
//! validator_corpus.rs and validator_inside_refs.rs.
//!
//! Usage :
//!   let errors = invalid_mutation_op_errors(&domain);
//!   // errors is empty for a bluebook whose every then_set names a known op.

use crate::ir::Domain;

/// Every command mutation the parser flagged with `invalid_op` — an unknown
/// `then_set` op. Reported INVALID-grade with the valid-op list, mirroring the
/// message the parser used to panic with before it recorded gracefully.
pub fn invalid_mutation_op_errors(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            for m in &cmd.mutations {
                if let Some(op) = &m.invalid_op {
                    errors.push(format!(
                        "Command {} then_set for `:{}` uses unknown op `{}:` — valid ops are \
                         to, append, append_unique, remove, increment, decrement, \
                         multiply, clamp, decay, from",
                        cmd.name, m.field, op
                    ));
                }
            }
        }
    }
    errors
}
