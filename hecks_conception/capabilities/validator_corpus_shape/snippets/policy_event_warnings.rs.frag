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
