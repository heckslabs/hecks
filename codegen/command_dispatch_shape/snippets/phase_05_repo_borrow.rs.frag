    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, &aggregate_name)
    };
    // i-cascade-fk : a cross-aggregate cascade (cascade_hint upstream type
    // differs from this aggregate) driving a self-ref command carries the
    // upstream event's leaked `id`, which names the UPSTREAM record, not one
    // of this type. Resolve the owning record from the upstream record's FK
    // (its attribute whose declared type IS this aggregate) so e.g.
    // TaskCompleted -> Story.DropPendingTaskCount finds the Story via Task.story.
    let cascade_fk_id: Option<String> = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name { return None; }
        // same-context upstream first : in combined-domain mode several
        // domains may share an aggregate name (e.g. Task), so prefer the one
        // in the target's context before falling back to any match.
        let up_agg = rt.domain.aggregates.iter()
            .find(|a| &a.name == up_type && a.context == aggregate_context)
            .or_else(|| rt.domain.aggregates.iter().find(|a| &a.name == up_type))?;
        let fname = up_agg.attributes.iter()
            .find(|at| at.attr_type == aggregate_name)
            .map(|at| at.name.clone())?;
        rt.repositories.get(&super::repo_key(up_agg.context.as_deref(), up_type))
            .and_then(|up| up.find(up_id))
            .and_then(|rec| rec.fields.get(&fname))
            .and_then(|v| v.as_str().map(str::to_string))
    });
    // i735 defect 2 — an aggregate whose `:sqlite` adapter was refused at
    // boot has NO repository (dropped, never silently swapped to heki).
    // Surface the loud reason instead of a misleading "unknown aggregate".
    if let Some(reason) = rt.refused_persistence.get(&repo_hash_key) {
        return Err(RuntimeError::PersistenceRefused(reason.clone()));
    }
    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;
