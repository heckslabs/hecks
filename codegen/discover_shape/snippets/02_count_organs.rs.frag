pub fn count_organs(conception_dir: &Path, info_dir: &str) -> OrganCounts {
    let agg_dir = conception_dir.join("aggregates");

    // i117 Round 4 nested aggregates into bounded-context subdirs
    // (discipline/, language/, library/, world/). Census walks recurse
    // rather than reading the flat top level. The body/ subset moved
    // out into the per-being repo (miette/body/) ; the conception
    // proper no longer carries organs. i118 R3 W2 lifted capabilities
    // from <conception>/capabilities/ to top-level repo buckets
    // (runtime/, codegen/, cli/, integrations/, tools/, discipline/).
    // count_organs walks all three roots so the boot print reflects
    // the real corpus :
    //
    //   organs        — miette/body/ recursive
    //   capabilities  — sum across the post-i118 R3 W2 buckets
    //   aggregates    — sum of `aggregates[]` across hecks_conception/
    //                   aggregates/ + miette/ + miette_family/
    //   nerves        — cross-domain policies across the same three
    //
    // Sibling roots (miette/, miette_family/, the top-level buckets)
    // resolve through heki::repo_root() so the math survives any
    // future bucket reorg without touching this file. Each sibling
    // walk is silently skipped when its directory doesn't exist
    // (CI-on-hecks-alone keeps working ; fresh-clone without the
    // per-being sibling repo prints the conception-only counts).
    let hecks_root = crate::heki::repo_root();
    let projects_root = hecks_root.as_ref().and_then(|p| p.parent());

    let organs = projects_root
        .map(|root| count_recursive_bluebooks(&root.join("miette/body")))
        .unwrap_or(0);

    let capabilities = hecks_root.as_ref().map(|root| {
        ["runtime", "codegen", "cli", "integrations", "tools", "discipline"]
            .iter()
            .map(|bucket| count_recursive_bluebooks(&root.join(bucket)))
            .sum()
    }).unwrap_or(0);

    let mut aggregates = 0usize;
    let mut nerves = 0usize;
    sum_aggregates_and_nerves(&agg_dir, &mut aggregates, &mut nerves);
    if let Some(root) = projects_root {
        sum_aggregates_and_nerves(&root.join("miette"), &mut aggregates, &mut nerves);
        sum_aggregates_and_nerves(&root.join("miette_family"), &mut aggregates, &mut nerves);
    }

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

