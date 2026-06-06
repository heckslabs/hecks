    let is_create = command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    // Cross-aggregate POINT gate pre-resolution (Slice 1). A `given` may read
    // one named sibling's field as `Agg(id_expr).field`. Resolve each here --
    // immutably, BEFORE the pipeline borrows the repository `&mut` -- and
    // inject the value into `attrs` so the pure interpreter resolves it via its
    // attrs fallback. The consistency boundary holds : still ONE aggregate
    // written ; this is a read at the gate (the port), never a cross write.
    let mut attrs = attrs;
    {
        let xref_cmd = cmd_for(rt, res);
        let self_id_opt = self_ref
            .as_ref()
            .and_then(|name| attrs.get(name).map(|v| v.to_string()))
            .or_else(|| attrs.get("id").map(|v| v.to_string()));
        let self_state = self_id_opt
            .as_deref()
            .and_then(|id| rt.find(&aggregate_name, id));
        resolve_cross_aggregate_gates(rt, xref_cmd, self_state, &mut attrs);
    }
