pub fn count_organs(conception_dir: &Path, info_dir: &str) -> OrganCounts {
    let agg_dir = conception_dir.join("aggregates");
    let body_dir = agg_dir.join("body");
    let cap_dir = conception_dir.join("capabilities");

    // i117 Round 4 nested aggregates into bounded-context subdirs
    // (body/, discipline/, language/, library/, mind/, self/, surface/,
    // world/). Census walks now recurse rather than reading the flat
    // top level. organs is specifically the body subset ; aggregates +
    // nerves walk the full tree.
    let organs = count_recursive_bluebooks(&body_dir);
    let capabilities = count_recursive_bluebooks(&cap_dir);

    let mut aggregates = 0usize;
    let mut nerves = 0usize;
    sum_aggregates_and_nerves(&agg_dir, &mut aggregates, &mut nerves);

    // Vows live as runtime records in <info_dir>/vow.heki — taken via
    // Vows.Take dispatch (2026-04-27). Count records, not declared
    // aggregates : the Vow aggregate spec is one declaration ; what
    // matters operationally is how many vows the being currently holds.
    let vows = count_vow_records(info_dir);

    OrganCounts { organs, capabilities, aggregates, nerves, vows }
}

fn sum_aggregates_and_nerves(dir: &Path, aggregates: &mut usize, nerves: &mut usize) {
    if !dir.is_dir() { return; }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                sum_aggregates_and_nerves(&p, aggregates, nerves);
            } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(src) = std::fs::read_to_string(&p) {
                    let domain = parser::parse(&src);
                    *aggregates += domain.aggregates.len();
                    *nerves += domain.policies.iter()
                        .filter(|p| p.target_domain.as_ref()
                            .map(|s| !s.is_empty()).unwrap_or(false))
                        .count();
                }
            }
        }
    }
}

fn count_vow_records(info_dir: &str) -> usize {
    let path = heki::path_for_lookup(info_dir.trim_end_matches("/"), "vow");
    heki::read(&path).map(|store| store.len()).unwrap_or(0)
}

