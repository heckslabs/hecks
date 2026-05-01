    let mut findings = Vec::new();
    for agg in &domain.aggregates {
        if let Some(lc) = &agg.lifecycle {
            check_aggregate(agg, lc, &mut findings);
        }
        check_given_coverage(agg, &mut findings);
        check_mutation_references(agg, &mut findings);
    }
    Report { findings }
