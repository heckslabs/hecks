        let projections = domain
            .aggregates
            .iter()
            .map(|agg| projection::auto_projection(&agg.name))
            .collect();

