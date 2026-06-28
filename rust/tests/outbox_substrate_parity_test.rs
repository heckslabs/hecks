//! outbox_substrate_parity_test — the engine bundles its own OutboundEvent
//! stdlib bluebook at `rust/resources/outbound_event.bluebook` (the canonical
//! copy baked into the binary via `Runtime::OUTBOX_SUBSTRATE`). The framework
//! conception keeps a copy at
//! `hecks_conception/aggregates/framework/hexagon/bluebook/outbound_event.bluebook`
//! (referenced by event_sourcing.bluebook, and an override per
//! `ensure_outbox_substrate`). This guards the two against DRIFT.
//!
//! Decouple-friendly by construction : it compares ONLY when the conception
//! copy is reachable (in the monorepo). Built standalone — storehouse extracted,
//! no sibling hecks_conception — the conception copy is absent and the test
//! SKIPS, so the engine's own suite never recouples to the conception.
//!
//! [antibody-exempt: rust/tests/outbox_substrate_parity_test.rs — a drift guard
//!  for the engine's bundled OutboundEvent stdlib vs the conception copy. Pure
//!  test scaffolding ; no domain.]

use std::path::PathBuf;

/// The crate-owned canonical copy — the same bytes baked into the binary.
const BUNDLED: &str = include_str!("../resources/outbound_event.bluebook");

/// Walk up from the test binary to the monorepo root (the dir holding
/// `hecks_conception/aggregates/`), mirroring `heki::walk_up_from`. Returns
/// None when no such ancestor exists (storehouse extracted / standalone).
fn conception_copy() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let mut cur = exe.parent()?.to_path_buf();
    for _ in 0..10 {
        let candidate = cur
            .join("hecks_conception/aggregates/framework/hexagon/bluebook/outbound_event.bluebook");
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

#[test]
fn bundled_outbox_matches_the_conception_copy() {
    let Some(path) = conception_copy() else {
        // Standalone build (no sibling hecks_conception) — nothing to compare.
        eprintln!("skip: conception copy not reachable (standalone build)");
        return;
    };
    let conception = std::fs::read_to_string(&path).expect("read conception copy");
    assert_eq!(
        BUNDLED, conception,
        "DRIFT: rust/resources/outbound_event.bluebook diverged from {}. \
         The engine's bundled OutboundEvent stdlib and the conception copy must \
         stay byte-identical — update both (or reconcile to one source).",
        path.display()
    );
}
