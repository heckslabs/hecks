    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or_else(|| RuntimeError::UnknownAggregate(aggregate_name.clone()))?;
