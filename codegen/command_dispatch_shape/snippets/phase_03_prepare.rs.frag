    // reference_to retirement step 1 : the `create` keyword (cmd.creates) is
    // the authoritative creation bit. Additive — true forces create ; false
    // falls through to the unchanged name-heuristic + reference_to path.
    let is_create = cmd_for(rt, res).creates
        || command_name.starts_with("Create")
        || command_name.starts_with("Add")
        || command_name.starts_with("Place")
        || command_name.starts_with("Register")
        || command_name.starts_with("Open");

    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    let attrs = attrs;
