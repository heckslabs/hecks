/// Corpus-aware variant of the retired per-file `valid_references` rule.
/// Checks every `reference_to(X)` declared by `domain` (on an aggregate or a
/// command) and resolves the target against the aggregate names present in
/// `corpus` — the merged corpus Domain. Qualified cross-domain refs
/// (`reference.domain.is_some()`) are validated elsewhere and skipped here.
///
/// TWO domains, two jobs : `domain` supplies the references to check ; `corpus`
/// supplies the universe of valid aggregate names. They are passed separately
/// (not merged) so a STAGED file outside the corpus dir still has its own refs
/// checked — the per-file `valid_references` coverage the corpus pass replaces
/// must not silently drop for out-of-corpus files.
///
/// Lives in the corpus pass — not in `validator.rs` — because a legitimate
/// unqualified `belongs_to` can target an aggregate that lives in a SIBLING
/// bluebook (e.g. `Conductor::Lease` references `Story` from plan.bluebook).
/// Under single-file load those siblings are absent, so the per-file check
/// false-positived. With the corpus joined, every aggregate is present, so
/// only a TRUE typo (`belongs_to Wrker`) survives as an error.
///
/// Whole-corpus audit call site passes `(corpus, corpus)` — identical to the
/// retired rule run over the merged domain.
///
/// Returns INVALID-grade errors — a dangling reference is always wrong,
/// regardless of aggregate count, so there is no `< 2 aggregates` guard.
pub fn unknown_aggregate_errors(domain: &Domain, corpus: &Domain) -> Vec<String> {
    let agg_names: HashSet<&str> = corpus
        .aggregates
        .iter()
        .map(|a| a.name.as_str())
        .collect();

    let mut errors = vec![];
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if reference.domain.is_some() {
                continue; // cross-domain refs validated elsewhere
            }
            if !agg_names.contains(reference.target.as_str()) {
                errors.push(format!(
                    "{} references unknown aggregate: {}",
                    agg.name, reference.target
                ));
            }
        }
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if reference.domain.is_some() {
                    continue;
                }
                if !agg_names.contains(reference.target.as_str()) {
                    errors.push(format!(
                        "Command {} references unknown aggregate: {}",
                        cmd.name, reference.target
                    ));
                }
            }
        }
    }
    errors
}
