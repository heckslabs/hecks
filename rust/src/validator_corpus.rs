//! Validator extensions that run against the corpus-merged Domain
//! (every bluebook in the corpus joined into one IR via
//! `load_combined_domain`). Live here rather than in `validator.rs`
//! or `validator_warnings.rs` because those two files are
//! specializer targets — byte-identical with what
//! `storehouse specialize <name>` emits — and adding hand-written
//! functions to them breaks the 2nd Futamura proof.
//!
//! GENERATED FILE — do not edit.
//! Source:    codegen/validator_corpus_shape/
//! Regenerate: storehouse specialize validator_corpus --output storehouse/src/validator_corpus.rs
//! Contract:  storehouse/src/specializer/validator_corpus.rs (Rust-native)
//!
//! Four rules :
//!
//!   - `corpus_phantom_trigger_errors` — INVALID-grade : a policy's
//!     `trigger_command` is not declared by any aggregate in the
//!     corpus. The runtime would explode at dispatch time.
//!
//!   - `identified_by_warnings` — advisory : an aggregate has a
//!     lifecycle or self-referencing command but no identified_by,
//!     so dispatch counter-mints a fresh id on every fire and the
//!     lifecycle state never advances past pending.
//!
//!   - `policy_event_warnings` — advisory : a policy subscribes to
//!     an event that no command emits anywhere in the corpus. The
//!     policy is dangling — placeholder, or a typo.
//!
//!   - `bare_name_collisions` — advisory : a command name is declared
//!     on more than one aggregate across the corpus. Bare-name
//!     dispatch is ambiguous — qualify call sites with
//!     `Aggregate.Command` to disambiguate. i156.

use std::collections::HashSet;

use crate::ir::Domain;

/// Corpus-wide variant of `valid_policy_triggers`. Same logic, but
/// expects `domain` to be a Domain produced by `load_combined_domain`
/// (every bluebook in the corpus merged into one IR). Walks every policy
/// and reports trigger commands missing from the corpus-wide command set.
///
/// Used by `validate --corpus <dir>` so the per-file `valid_policy_triggers`
/// stays silent on cross-bluebook flow (where the trigger lives in another
/// file) while the corpus pass catches the truly phantom case.
///
/// Returns INVALID-grade errors — a phantom trigger errors at dispatch
/// time, so the runtime would explode anyway. Empty vec when called on
/// a Domain with fewer than 2 aggregates (single-file mode).
pub fn corpus_phantom_trigger_errors(domain: &Domain) -> Vec<String> {
    if domain.aggregates.len() < 2 {
        return vec![];
    }
    let all_commands: HashSet<&str> = domain
        .aggregates
        .iter()
        .flat_map(|a| a.commands.iter().map(|c| c.name.as_str()))
        .collect();

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none())
        .filter(|p| !all_commands.contains(p.trigger_command.as_str()))
        .map(|p| {
            format!(
                "Policy {} triggers unknown command in corpus: {}",
                p.name, p.trigger_command
            )
        })
        .collect()
}

/// Flags aggregates that have a `lifecycle` block OR a self-referencing
/// `reference_to` (a command pointing back to its own aggregate) but
/// declare no `identified_by`. Without `identified_by`, the in-memory
/// runner counter-mints a fresh u64 id on every dispatch — the lifecycle
/// state never advances past `pending`, and the self-ref form (used by
/// transition commands) targets a fresh record each time.
///
/// Skipped when the aggregate has `identified_by` already, or when it
/// has neither a lifecycle nor a self-ref (event-log style stores
/// legitimately want counter-mint behavior).
///
/// Per-bluebook check — no corpus context required. Returns one warning
/// per offending aggregate.
pub fn identified_by_warnings(domain: &Domain) -> Vec<String> {
    let mut warnings = vec![];
    for agg in &domain.aggregates {
        if agg.identified_by.is_some() {
            continue;
        }
        let has_lifecycle = agg.lifecycle.is_some();
        let has_self_ref = agg.commands.iter().any(|cmd| {
            cmd.references.iter().any(|r| r.target == agg.name && r.domain.is_none())
        });
        if !has_lifecycle && !has_self_ref {
            continue;
        }
        warnings.push(format!(
            "⚠ aggregate '{}' has a {} but no identified_by — consider 'identified_by :name' so the in-memory runner converges on a single record",
            agg.name,
            if has_lifecycle { "lifecycle" } else { "self-referencing command" }
        ));
    }
    warnings
}

/// Corpus-wide check: flags policies whose `on_event` is emitted by no
/// command anywhere in the merged Domain. The policy is dangling — it
/// will never fire. This is advisory, not blocking : an event with no
/// current emitter could be intentional (placeholder for a future
/// bluebook).
///
/// Companion to the existing `valid_policy_triggers` rule in validator.rs
/// (which flags missing trigger commands as INVALID). The two functions
/// together catch both ends of the policy/event coherence problem when
/// the Domain has been merged across the corpus.
///
/// When called on a single-file Domain (no corpus merge) the function
/// returns no findings — flagging on a partial Domain would produce
/// false positives for cross-bluebook event flow.
pub fn policy_event_warnings(domain: &Domain) -> Vec<String> {
    // Single-file heuristic : if the Domain has fewer than 2 aggregates
    // OR no policies cross aggregate names, we lack the corpus context
    // to make corpus-wide claims. Skip silently.
    if domain.policies.is_empty() || domain.aggregates.len() < 2 {
        return vec![];
    }

    let mut emitted: HashSet<&str> = HashSet::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if let Some(ref e) = cmd.emits {
                emitted.insert(e.as_str());
            }
        }
    }

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none())
        .filter(|p| !emitted.contains(p.on_event.as_str()))
        .map(|p| {
            format!(
                "⚠ policy '{}' subscribes to event '{}' that no command emits in the corpus — placeholder for future bluebook, or a typo ?",
                p.name, p.on_event
            )
        })
        .collect()
}

/// Corpus-wide check : flags command names declared on more than one
/// aggregate across the merged Domain. Bare-name dispatch (`Command`
/// without an `Aggregate.` or `Context.Aggregate.` prefix) is resolved
/// by first-match-wins iteration order in `command_dispatch::resolve`,
/// so a colliding bare name silently routes to whichever aggregate the
/// resolver visits first. The fix is for callers to qualify the
/// dispatch site (`Aggregate.Command`) — this rule surfaces the
/// dependency.
///
/// Walks `domain.aggregates[*].commands[*]`, groups by command name,
/// emits one warning per command name that appears on more than one
/// distinct aggregate. The warning lists the candidate aggregates
/// (sorted) so authors can see exactly which bluebooks collide.
///
/// Returns advisory warnings — the runtime still resolves bare names
/// (gated behind the env var `HECKS_STRICT_DISPATCH=1` for opt-in
/// strict mode until the corpus is fully migrated to qualified call
/// sites). i156.
pub fn bare_name_collisions(domain: &Domain) -> Vec<String> {
    if domain.aggregates.len() < 2 {
        return vec![];
    }
    let mut by_name: std::collections::BTreeMap<&str, std::collections::BTreeSet<&str>> =
        std::collections::BTreeMap::new();
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            by_name
                .entry(cmd.name.as_str())
                .or_default()
                .insert(agg.name.as_str());
        }
    }
    by_name
        .into_iter()
        .filter(|(_, aggs)| aggs.len() > 1)
        .map(|(name, aggs)| {
            let candidates: Vec<&str> = aggs.into_iter().collect();
            format!(
                "⚠ command name '{}' declared on aggregates [{}] across the corpus — bare-name dispatch is ambiguous, qualify call sites with `<Aggregate>.{}`",
                name,
                candidates.join(", "),
                name
            )
        })
        .collect()
}
