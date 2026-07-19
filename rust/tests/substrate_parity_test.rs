//! substrate_parity_test — the engine bundles its own framework stdlib
//! bluebooks under `rust/resources/` (the canonical copies baked into the
//! binary via `Runtime::OUTBOX_SUBSTRATE` / `Runtime::EVENT_SOURCING_SUBSTRATE`).
//! The framework conception keeps a copy of each. This guards them against
//! DRIFT.
//!
//! Two substrates today :
//!   - OutboundEvent  — the event-out messaging port
//!   - EventSourcing  — the Event Log the framework collaborator appends to
//!
//! This guard EARNS ITS KEEP : on 2026-07-19 the outbox copy was edited on one
//! side only and seven tests went red immediately, which is exactly the job.
//! The standing intent (CARD-framework-substrate-service) is to retire the
//! duplication itself by having the collaborator own the substrate outright —
//! at which point this file goes away rather than growing a third entry.
//! Adding a substrate here is a cost, not a feature.
//!
//! Decouple-friendly by construction : each pair is compared ONLY when the
//! conception copy is reachable (in the monorepo). Built standalone —
//! storehouse extracted, no sibling hecks_conception — the conception copy is
//! absent and that comparison SKIPS, so the engine's own suite never recouples
//! to the conception.
//!
//! [antibody-exempt: rust/tests/substrate_parity_test.rs — a drift guard for the
//!  engine's bundled framework stdlib vs the conception copies. Pure test
//!  scaffolding ; no domain.]

use std::path::PathBuf;

/// The crate-owned canonical copies — the same bytes baked into the binary.
const BUNDLED_OUTBOX: &str = include_str!("../resources/outbound_event.bluebook");
const BUNDLED_EVENT_SOURCING: &str = include_str!("../resources/event_sourcing.bluebook");

/// Walk up from the test binary to the monorepo root (the dir holding
/// `hecks_conception/aggregates/`), mirroring `heki::walk_up_from`, and resolve
/// `relative` beneath it. None when no such ancestor exists (storehouse
/// extracted / standalone build).
fn conception_copy(relative: &str) -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let mut cur = exe.parent()?.to_path_buf();
    for _ in 0..10 {
        let candidate = cur.join(relative);
        if cur.join("hecks_conception/aggregates").is_dir() && candidate.is_file() {
            return Some(candidate);
        }
        let parent = cur.parent()?.to_path_buf();
        if parent == cur {
            break;
        }
        cur = parent;
    }
    None
}

/// Compare one bundled substrate against its conception copy, skipping when the
/// conception is unreachable.
fn assert_matches(label: &str, bundled: &str, relative: &str) {
    let Some(path) = conception_copy(relative) else {
        eprintln!("skip: {} conception copy not reachable (standalone build)", label);
        return;
    };
    let conception = std::fs::read_to_string(&path).expect("read conception copy");
    assert_eq!(
        bundled,
        conception,
        "DRIFT: the bundled {} substrate diverged from {}. The engine's baked-in \
         copy and the conception copy must stay byte-identical — update both, or \
         reconcile to one source (see CARD-framework-substrate-service).",
        label,
        path.display(),
    );
}

#[test]
fn bundled_outbox_matches_the_conception_copy() {
    assert_matches(
        "OutboundEvent",
        BUNDLED_OUTBOX,
        "hecks_conception/aggregates/framework/hexagon/bluebook/outbound_event.bluebook",
    );
}

#[test]
fn bundled_event_sourcing_matches_the_conception_copy() {
    // Bundled 2026-07-19 so the framework collaborator can boot the Event Log
    // on a single-bluebook boot, with no corpus and no sibling conception.
    assert_matches(
        "EventSourcing",
        BUNDLED_EVENT_SOURCING,
        "hecks_conception/aggregates/framework/event_sourcing/bluebook/event_sourcing.bluebook",
    );
}
