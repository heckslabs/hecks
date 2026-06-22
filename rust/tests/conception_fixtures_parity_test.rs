//! conception_fixtures_parity_test — the engine's framework-integration tests
//! embed 13 conception hecksagons (conductor + plan sweeps/cascades) as
//! ENGINE-OWNED fixtures at `rust/tests/fixtures/conception/`, so the crate
//! compiles STANDALONE (no `include_str!` reaching into a sibling
//! `hecks_conception/`). Those fixtures are frozen copies ; this guards them
//! against DRIFT from the conception originals.
//!
//! Decouple-friendly by construction : it compares ONLY when the conception is
//! reachable (the monorepo, `CARGO_MANIFEST_DIR/../hecks_conception`). Built
//! standalone — storehouse extracted, no sibling conception — the originals are
//! absent and the test SKIPS, so the engine's own suite never recouples.
//!
//! [antibody-exempt: rust/tests/conception_fixtures_parity_test.rs — a drift
//!  guard for the engine's frozen conception test-fixtures vs the conception
//!  originals. Pure test scaffolding ; no domain.]

use std::path::PathBuf;

/// (domain, hecksagon-stem) for every fixture under tests/fixtures/conception/.
const FIXTURES: &[(&str, &str)] = &[
    ("conductor", "claim_next_on_claim_released"),
    ("conductor", "claim_next_on_worker_registered"),
    ("conductor", "expiry_sweep"),
    ("conductor", "liveness_sweep"),
    ("conductor", "reclaim_on_expire"),
    ("conductor", "story_worktree_sync"),
    ("conductor", "volunteer_pull"),
    ("conductor", "worker_died_reclaim"),
    ("plan", "activate_sprint_on_project"),
    ("plan", "assign_story_on_sprint_add"),
    ("plan", "reset_story_tasks"),
    ("plan", "resolve_deps"),
    ("plan", "seed_sprint_active"),
];

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

#[test]
fn fixtures_match_conception_originals() {
    let conception = crate_dir().join("../hecks_conception/aggregates");
    if !conception.is_dir() {
        eprintln!("skip: conception not reachable (standalone build)");
        return;
    }
    let mut drift = Vec::new();
    for (domain, stem) in FIXTURES {
        let fixture = crate_dir().join(format!("tests/fixtures/conception/{domain}/{stem}.hecksagon"));
        let original = conception.join(format!("{domain}/hecksagons/{stem}.hecksagon"));
        let f = std::fs::read_to_string(&fixture).expect("read fixture");
        let o = std::fs::read_to_string(&original).expect("read conception original");
        if f != o {
            drift.push(format!("{domain}/{stem}"));
        }
    }
    assert!(
        drift.is_empty(),
        "DRIFT: engine fixtures diverged from the conception originals: {drift:?}. \
         Re-copy them from hecks_conception/aggregates/<domain>/hecksagons/ (the \
         frozen test fixtures must stay byte-identical to the source)."
    );
}
