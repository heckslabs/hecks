    // belongs_to-on-event — the aggregate's stored belongs_to FKs ride its
    // emitted event so downstream adapters can bind them (the freed worker on
    // ClaimReleased -> SEAM 1 retrigger ; the story on LeaseReclaimed -> worktree
    // unlock). Command inputs win on collision ; empty FKs are skipped.
    let mut event_data = attrs.clone();
    for r in &rt.domain.aggregates[agg_idx].references {
        if matches!(r.kind, crate::ir::ReferenceKind::BelongsTo)
            && !event_data.contains_key(&r.name)
        {
            let v = state.get(&r.name);
            if !v.to_string().is_empty() {
                event_data.insert(r.name.clone(), v.clone());
            }
        }
    }
    let aggregate_id = state.id.clone();
    let was_deleted = state.deleted;
    let ctx = crate::heki::WriteContext::Dispatch {
        aggregate: &aggregate_name, command: command_name,
    };
    let repo = rt.repositories.get_mut(&repo_hash_key).unwrap();
    if was_deleted {
        repo.delete(&aggregate_id, ctx);
    } else {
        repo.save(state, ctx);
    }
