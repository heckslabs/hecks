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
    // Event-sourcing deltas — the fields whose value changed vs. the
    // pre-command snapshot. A lifecycle transition is just another changed
    // field here (status: pending -> authorized), so it needs no special-
    // casing. Computed BEFORE save (which moves state). record_event_append
    // appends one immutable Log Event per delta.
    let deltas: Vec<(String, Value)> = state.fields.iter()
        .filter(|(k, v)| before_fields.get(*k) != Some(*v))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    // deciderate Layer 0b — the CHANGED state fields (deltas) ride the emitted
    // event so a policy can GUARD on the RESULTING state, not just the command
    // inputs (e.g. `where games_remaining: 0` after a decrement — the Bracket
    // saga's round-complete condition). The delta WINS over a same-named
    // command input : the event must carry what the command RESULTED IN, not
    // what was requested. This is essential when a for_each SWEEP passes the
    // swept record's PRE-mutation field (e.g. Bubble.Decay receives the floating
    // bubble's old `size`) and then mutates it — the guard (`where size: 0`)
    // must see the post-decrement value, not the stale swept input. Untouched
    // input fields (never in deltas) are left as-is.
    for (k, v) in &deltas {
        event_data.insert(k.clone(), v.clone());
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
