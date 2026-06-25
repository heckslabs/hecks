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
