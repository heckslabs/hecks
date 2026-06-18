/// Corpus-aware ambiguity check : an UNQUALIFIED cross reference
/// (`has_one` / `has_many` / `belongs_to`, no `from <Context>`) whose target
/// NAME is declared by more than one aggregate across the corpus, with NO
/// same-context candidate, cannot be resolved without guessing. The
/// relationship grammar's rule is that ambiguity is an ERROR, not a silent
/// guess — so this is INVALID-grade.
///
/// Mirrors the runtime's reference resolution (`command_dispatch` resolves a
/// reference to a SAME-CONTEXT aggregate first), so a reference the runtime
/// resolves cleanly never errors here : if any candidate shares the referrer's
/// context, the reference resolves and stays silent. Only a target living in
/// 2+ OTHER contexts (none the referrer's) is ambiguous, and the fix is the
/// English `from <Context>` qualifier.
///
/// Inside references (`list_of` / `reference_to`, local identity) are never
/// cross-context, so only `BelongsTo` / `HasOne` / `HasMany` are checked.
/// Already-qualified refs (`reference.domain.is_some()`) name their context
/// and are skipped. `domain` supplies the references to check ; `corpus`
/// supplies the universe of aggregate names + contexts — the same two-domain
/// split as `unknown_aggregate_errors`.
pub fn ambiguous_cross_reference_errors(domain: &Domain, corpus: &Domain) -> Vec<String> {
    use crate::ir::{Reference, ReferenceKind};
    let mut errors = vec![];
    for agg in &domain.aggregates {
        let referrer_ctx = agg.context.as_deref();
        let mut refs: Vec<(String, &Reference)> = vec![];
        for r in &agg.references {
            refs.push((format!("{} {} {}", agg.name, r.kind.as_str(), r.target), r));
        }
        for cmd in &agg.commands {
            for r in &cmd.references {
                refs.push((format!("Command {} {} {}", cmd.name, r.kind.as_str(), r.target), r));
            }
        }
        for (label, reference) in refs {
            if reference.domain.is_some() {
                continue; // already qualified with `from <Context>`
            }
            if !matches!(
                reference.kind,
                ReferenceKind::BelongsTo | ReferenceKind::HasOne | ReferenceKind::HasMany
            ) {
                continue; // inside refs (list_of / reference_to) are never cross-context
            }
            let candidates: Vec<&str> = corpus
                .aggregates
                .iter()
                .filter(|a| a.name == reference.target)
                .map(|a| a.context.as_deref().unwrap_or("—"))
                .collect();
            if candidates.len() < 2 {
                continue; // unique (resolves) or unknown (unknown_aggregate_errors owns it)
            }
            if corpus
                .aggregates
                .iter()
                .any(|a| a.name == reference.target && a.context.as_deref() == referrer_ctx)
            {
                continue; // a same-context candidate resolves it, exactly as the runtime does
            }
            let mut ctxs = candidates;
            ctxs.sort();
            ctxs.dedup();
            errors.push(format!(
                "{} is ambiguous — '{}' is declared in contexts [{}] ; qualify with `{} from <Context>`",
                label,
                reference.target,
                ctxs.join(", "),
                reference.target
            ));
        }
    }
    errors
}
