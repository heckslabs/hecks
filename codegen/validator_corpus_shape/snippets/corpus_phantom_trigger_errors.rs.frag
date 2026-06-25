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
