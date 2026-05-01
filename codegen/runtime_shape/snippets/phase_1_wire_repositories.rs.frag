        let mut repositories = HashMap::new();
        for agg in &domain.aggregates {
            // i142 Tier 2 — key repositories by (context, name) so
            // same-name aggregates in different contexts get distinct
            // Repository instances (and distinct heki paths).
            let key = repo_key(agg.context.as_deref(), &agg.name);
            repositories.insert(
                key,
                Repository::new_with_context(
                    &agg.name,
                    data_dir.clone(),
                    agg.identified_by.clone(),
                    agg.context.clone(),
                ),
            );
        }

