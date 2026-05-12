    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, &aggregate_name)
    };
    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;
