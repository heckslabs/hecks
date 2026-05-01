    // i111-K — same-type cascade id preservation. When the cascade
    // hopped Aggregate → Aggregate (same type) and a record exists at
    // the upstream id, reuse it. This runs BEFORE id_for_command so it
    // overrides counter-mint behavior for aggregates without
    // identified_by — closing the i111-C identified_by-required gap.
    let cascade_id = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name {
            rt.repositories.get(&repo_hash_key)
                .and_then(|repo| repo.find(up_id))
                .map(|_| up_id.clone())
        } else {
            None
        }
    });
