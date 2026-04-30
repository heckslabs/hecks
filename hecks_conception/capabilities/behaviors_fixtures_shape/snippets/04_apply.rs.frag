/// Seed a fresh runtime with fixture data. Creates one AggregateState
/// per fixture record under sequential integer ids ("1", "2", ...),
/// which matches `pre_seed_singletons`' id convention. The FIRST
/// fixture per aggregate wins the in_scope slot — what references
/// resolve to when a command needs a sibling aggregate's id.
///
/// Returns the in_scope delta so the runner can merge it into its
/// own map (alongside `pre_seed_singletons` results).
pub fn apply(rt: &mut Runtime, fixtures: &FixturesFile) -> HashMap<String, String> {
    let mut in_scope: HashMap<String, String> = HashMap::new();

    // Group fixtures by aggregate so ids are per-aggregate-contiguous,
    // matching the Ruby loader.
    let mut by_agg: HashMap<String, Vec<&crate::ir::Fixture>> = HashMap::new();
    for f in &fixtures.fixtures {
        by_agg.entry(f.aggregate_name.clone()).or_default().push(f);
    }

    for (agg_name, list) in by_agg {
        // Fixture references an aggregate the domain doesn't define —
        // skip silently; the source bluebook/fixtures file authors will
        // see zero seed effect and can fix the mismatch.
        // i142 Tier 2 — fixtures don't declare context, so use the
        // name-scan helper to find the matching repository regardless
        // of context-prefixed keys.
        let Some(key) = crate::runtime::repo_lookup_key(&rt.repositories, &agg_name) else { continue };
        let Some(repo) = rt.repositories.get_mut(&key) else { continue };
        for (i, fix) in list.iter().enumerate() {
            let id = (i + 1).to_string();
            let mut state = AggregateState::new(&id);
            for (key, raw) in &fix.attributes {
                state.set(key, parse_fixture_value(raw));
            }
            repo.save(state, crate::heki::WriteContext::OutOfBand {
                reason: "behaviors test fixture seed — loads .fixtures rows into aggregate repos for test setup",
            });
            in_scope.entry(agg_name.clone()).or_insert_with(|| id.clone());
        }
    }

    in_scope
}

