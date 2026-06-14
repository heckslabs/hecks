//! Phase-A persistence-enforcement gate (i728) — the EMPTY-diff invariant.
//!
//! [antibody-exempt: rust/tests/backend_map_phase_a_test.rs — infrastructure
//!  test asserting LazyRepository backend resolution at boot, like
//!  sqlite_scope_test.rs / persistence_recovery_test.rs (both exempt) ;
//!  behaviours suites are pure-memory and cannot observe per-repo backend kind.]
//!
//! The keystone change (removing the parser's `None→"memory"` normalization) is
//! ADDITIVE : `apply_memory_persistence` is NOT wired until Phase B, so an
//! explicit `adapter :memory` must NOT flip its repository to `Backend::Memory`.
//! No production aggregate changes backend in Phase A — proven here by booting
//! the real conception with a `:memory` hecksagon attached and asserting that
//! `dump_backend_map()` reports ZERO memory-backed repositories. A non-empty
//! memory set is an automatic stop, not a reviewable gate.
//!
//! `dump_backend_map()` / `backend_kind()` / `heki_path()` are the read-only
//! introspection Phase B's classification surface and Phase C's resolution
//! rewrite build on ; this test also pins their correctness.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{BackendKind, LazyRepository, Runtime};

fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}

// An explicit `adapter :memory` for the Inbox context — one of the 14 real
// :memory hecksagons. In Phase A this must stay INERT : memory-selection is not
// wired, so Inbox keeps the heki default rather than flipping to Backend::Memory.
const INBOX_MEMORY_HEX: &str = "Hecks.hecksagon \"Inbox\" do\n  adapter :memory\nend\n";

#[test]
fn explicit_memory_does_not_flip_backend_in_phase_a() {
    let domain = load_combined_domain(&aggregates_dir());
    let rt = Runtime::boot_with_hecksagons(
        domain,
        None,
        vec![hecksagon_parser::parse(INBOX_MEMORY_HEX)],
    );

    let map = rt.dump_backend_map();
    let memory_backed: Vec<&str> = map
        .iter()
        .filter(|b| b.kind == BackendKind::Memory)
        .map(|b| b.repo_key.as_str())
        .collect();
    assert!(
        memory_backed.is_empty(),
        "Phase A must flip NO aggregate to Backend::Memory until Phase B wires \
         apply_memory_persistence (found: {memory_backed:?})",
    );
}

#[test]
fn dump_backend_map_reports_heki_default_with_path() {
    let domain = load_combined_domain(&aggregates_dir());
    let rt = Runtime::boot_with_hecksagons(domain, Some("/tmp/i728_gate".into()), vec![]);
    let map = rt.dump_backend_map();

    assert!(!map.is_empty(), "the conception has repositories");
    assert!(
        map.iter().all(|b| b.kind == BackendKind::Heki),
        "with no :memory/:sqlite hecksagons, every repo resolves to the heki default",
    );
    assert!(
        map.iter().any(|b| b.heki_path.as_deref() == Some("/tmp/i728_gate")),
        "heki_path is populated for heki-backed repos",
    );
}

#[test]
fn unwired_aggregates_dormant_check_reports_undeclared() {
    let domain = load_combined_domain(&aggregates_dir());
    // Attach a wired :heki hecksagon for the Governance context.
    let gov = hecksagon_parser::parse("Hecks.hecksagon \"Governance\" do\n  adapter :heki\nend\n");
    let rt = Runtime::boot_with_hecksagons(domain, None, vec![gov]);

    let unwired = rt.unwired_aggregates();
    // Pre-migration, most conception aggregates have no persistence hecksagon.
    assert!(!unwired.is_empty(), "the conception has unwired aggregates pre-migration");
    // The wired Governance context is excluded from the unwired set.
    assert!(
        !unwired.iter().any(|k| k.starts_with("Governance::")),
        "Governance is wired :heki — must not appear as unwired",
    );
}

#[test]
fn backend_kind_distinguishes_explicit_memory() {
    // The accessor Phase B relies on : new_memory IS Memory-backed, no heki path.
    let repo = LazyRepository::new_memory("Order", Some("id".into()), None);
    assert_eq!(repo.backend_kind(), BackendKind::Memory);
    assert_eq!(repo.heki_path(), None);
    assert!(!repo.is_sql());
}
