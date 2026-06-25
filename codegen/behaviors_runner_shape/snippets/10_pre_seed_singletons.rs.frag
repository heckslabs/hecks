/// For every aggregate where every command requires a self-ref to its
/// own type, manually seed an empty AggregateState at id "1" so the
/// reference-injection layer has something to point at. Lifecycle
/// defaults are applied so commands with `given { state == "<default>" }`
/// can match against the virgin record (i511).
fn pre_seed_singletons(rt: &mut Runtime, in_scope: &mut HashMap<String, String>) {
    let to_seed: Vec<(String, Option<String>, usize)> = rt.domain.aggregates.iter()
        .enumerate()
        .filter(|(_, agg)| agg_has_no_bootstrap(agg))
        .map(|(idx, agg)| (agg.name.clone(), agg.context.clone(), idx))
        .collect();
    for (agg_name, agg_ctx, agg_idx) in to_seed {
        // Fixtures seeded this aggregate already — don't overwrite its
        // loaded state with a virgin AggregateState at id "1".
        if in_scope.contains_key(&agg_name) { continue; }
        let key = crate::runtime::repo_key(agg_ctx.as_deref(), &agg_name);
        let id = "1".to_string();
        let mut state = crate::runtime::AggregateState::new(&id);
        crate::runtime::apply_lifecycle_default(rt, agg_idx, &mut state);
        if let Some(repo) = rt.repositories.get_mut(&key) {
            repo.save(state,
                crate::heki::WriteContext::OutOfBand {
                    reason: "behaviors test runner — pre-seed empty singleton at id=1 for cross-aggregate setup",
                });
            in_scope.insert(agg_name, id);
        }
    }
}

