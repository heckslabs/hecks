pub fn count_organs(conception_dir: &Path) -> OrganCounts {
    let agg_dir = conception_dir.join("aggregates");
    let cap_dir = conception_dir.join("capabilities");

    let organs = count_top_level_bluebooks(&agg_dir);
    let capabilities = count_recursive_bluebooks(&cap_dir);

    let mut aggregates = 0usize;
    let mut nerves = 0usize;
    let mut vows = 0usize; // see module docs

    if let Ok(entries) = std::fs::read_dir(&agg_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(src) = std::fs::read_to_string(&p) {
                    let domain = parser::parse(&src);
                    aggregates += domain.aggregates.len();
                    nerves += domain.policies.iter()
                        .filter(|p| p.target_domain.as_ref()
                            .map(|s| !s.is_empty()).unwrap_or(false))
                        .count();
                }
            }
        }
    }

    OrganCounts { organs, capabilities, aggregates, nerves, vows }
}

