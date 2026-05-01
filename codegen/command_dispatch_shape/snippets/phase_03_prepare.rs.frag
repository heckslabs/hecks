    let is_create = command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);
