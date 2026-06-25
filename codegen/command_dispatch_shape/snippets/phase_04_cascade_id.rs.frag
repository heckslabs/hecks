    // i111-K — same-type cascade id preservation. When the cascade
    // hopped Aggregate → Aggregate (same type) and a record exists at
    // the upstream id, reuse it. This runs BEFORE id_for_command so it
    // overrides counter-mint behavior for aggregates without
    // identified_by — closing the i111-C identified_by-required gap.
    let cascade_id = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name {
            // A same-type cascade must NOT hijack the identity of a command that
            // supplies its OWN id via the aggregate's identified_by field in attrs
            // (e.g. Claim.Acquire(story=s2) cascaded from ClaimReleased(s1) must
            // CREATE s2, not update s1). Only reuse the upstream id when the
            // command brings no explicit identity.
            let supplies_own_id = rt.domain.aggregates[agg_idx].identified_by
                .as_ref()
                .map_or(false, |idf| attrs.get(idf).map_or(false, |v| !v.to_string().is_empty()));
            if supplies_own_id {
                return None;
            }
            rt.repositories.get(&repo_hash_key)
                .and_then(|repo| repo.find(up_id))
                .map(|_| up_id.clone())
        } else {
            None
        }
    });
