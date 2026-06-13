    // First-class factories phase 1 : a verb that names a Factory on the
    // resolved aggregate IS a birth — the node type carries the bit the
    // #729 creates bool used to. The name-heuristic survives only until
    // phase 2 replaces this whole block with the two-path split
    // (Factory → mint, Command → load).
    let is_factory_verb = {
        let resolved_name = &cmd_for(rt, res).name;
        match res {
            Resolution::Aggregate(a, _) => rt.domain.aggregates[a]
                .factories.iter().any(|f| &f.name == resolved_name),
            Resolution::Entity(..) => false,
        }
    };
    let is_create = is_factory_verb
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
