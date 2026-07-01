//! validator_inside_refs.rs — the per-file INSIDE-boundary reference check.
//!
//! `reference_to X` (ReferenceKind::LegacyReferenceTo) is an INSIDE-boundary
//! reference by the Relationship grammar : it names a same-context sibling
//! aggregate or the aggregate itself (the self-ref transition-command form),
//! by LOCAL identity. Unlike the CROSS kinds (`belongs_to` / `has_one` /
//! `has_many`, GLOBAL identity), it NEVER legitimately targets another
//! bluebook — so its resolution universe is a SINGLE FILE, and a dangling
//! `reference_to Typo` is provable with no corpus context.
//!
//! That makes it the one reference kind a bare `storehouse validate <file>`
//! can check without the false positives that retired the old per-file
//! `valid_references` rule (which choked on a legitimate cross-bluebook
//! `belongs_to`). The CROSS kinds stay corpus-gated in
//! `validator_corpus::unknown_aggregate_errors` /
//! `ambiguous_cross_reference_errors`, which run under `--check-references` /
//! `--corpus`.
//!
//! Wired into the BARE `validate` path ONLY : in corpus modes the corpus
//! rules already resolve `reference_to` against the joined corpus, so running
//! this too would double-report. Closes the silent-failure hole where
//! `reference_to NonExistentAggregate` sailed through a newcomer's first
//! `validate` (DX perfection game, Tier 0 #4).
//!
//! Hand-written framework source — lives outside `validator.rs` /
//! `validator_warnings.rs`, which are specializer targets held byte-identical
//! with `storehouse specialize` (adding functions there breaks the 2nd
//! Futamura proof). Same reason `validator_corpus.rs` is hand-written.
//!
//! Usage :
//!   let errors = dangling_inside_reference_errors(&domain);
//!   // errors is empty for a self-contained bluebook whose every
//!   // `reference_to` resolves to a declared sibling or itself.

use std::collections::HashSet;

use crate::ir::{Domain, Reference, ReferenceKind};

/// Every `reference_to X` (LegacyReferenceTo kind) — declared on an aggregate
/// or a command — whose target X is not an aggregate declared in THIS domain.
/// Inside-boundary refs resolve within the single file, so an absent target is
/// a genuine dangling reference (a typo, or a forward-reference to an
/// aggregate that was never written). Reported INVALID-grade.
///
/// Only `LegacyReferenceTo` is checked : the cross kinds (`belongs_to` /
/// `has_one` / `has_many`) may legitimately target a sibling bluebook and are
/// resolved with corpus context in `validator_corpus`. Qualified refs
/// (`reference.domain.is_some()`, i.e. `X from <Context>`) name their context
/// and are skipped — the corpus pass owns them.
///
/// Resolution semantics are IDENTICAL to `unknown_aggregate_errors`, narrowed
/// to the inside kind and a single-file universe : anything this flags in bare
/// mode the corpus pass would also flag for a self-contained file, so the two
/// modes never disagree on `reference_to`.
pub fn dangling_inside_reference_errors(domain: &Domain) -> Vec<String> {
    let agg_names: HashSet<&str> = domain
        .aggregates
        .iter()
        .map(|a| a.name.as_str())
        .collect();

    let mut errors = vec![];
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if let Some(err) = dangling(&agg_names, reference, &agg.name, None) {
                errors.push(err);
            }
        }
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if let Some(err) = dangling(&agg_names, reference, &agg.name, Some(&cmd.name)) {
                    errors.push(err);
                }
            }
        }
    }
    errors
}

/// Resolve one reference against the same-file aggregate names. Returns the
/// error string when a `reference_to` (inside kind, unqualified) dangles ;
/// `None` when the reference is a cross kind, is qualified, or resolves.
fn dangling(
    agg_names: &HashSet<&str>,
    reference: &Reference,
    agg_name: &str,
    cmd_name: Option<&str>,
) -> Option<String> {
    if !matches!(reference.kind, ReferenceKind::LegacyReferenceTo) {
        return None; // cross kinds resolve with corpus context, not here
    }
    if reference.domain.is_some() {
        return None; // `X from <Context>` — the corpus pass owns it
    }
    if agg_names.contains(reference.target.as_str()) {
        return None; // resolves to a same-file aggregate (a sibling or itself)
    }
    let site = match cmd_name {
        Some(cmd) => format!("Command {}", cmd),
        None => agg_name.to_string(),
    };
    Some(format!(
        "{} references unknown aggregate: {} — `reference_to` must name an aggregate declared in this bluebook",
        site, reference.target
    ))
}
