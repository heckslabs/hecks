    // Pure upsert on identity (Relationship grammar, 2026-06-18) — create
    // vs update is a PERSISTENCE contract, not a declaration. Resolve the
    // identity from every source, then find-or-create : present -> update,
    // absent -> insert. No name heuristic, no reference_to(Self) error-on-
    // absent — the row's existence IS the create/update bit, so AddStory
    // can no longer mint a phantom Sprint. `find_self_ref_res` survives
    // only to keep resolving the id a legacy `reference_to` kwarg carries
    // (e.g. `sprint=`) until the corpus drops the self-ref form ; new
    // commands resolve via the universal `id` key or id_for_command.
    let resolved_id = if let Some(ref_name) = &self_ref {
        attrs.get(ref_name).map(|v| v.to_string())
            .or_else(|| cascade_fk_id.clone())
            .or_else(|| attrs.get("id").map(|v| v.to_string()))
            .or_else(|| cascade_id.clone())
            .unwrap_or_else(|| repo.id_for_command(&attrs))
    } else if let Some(id) = cascade_id.clone() {
        id
    } else {
        repo.id_for_command(&attrs)
    };
    let (mut state, is_new) = match repo.find(&resolved_id).cloned() {
        Some(s) => (s, false),
        None => (AggregateState::new(&resolved_id), true),
    };
