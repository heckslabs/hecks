    if is_new {
        apply_defaults(rt, agg_idx, &mut state);
        apply_lifecycle_default(rt, agg_idx, &mut state);
    }
