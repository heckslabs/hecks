//! Clock / liveness-sweep end-to-end (decision A).
//!
//! A Sweeper.Tick fans Worker.MarkDead out over Worker.Stale (alive workers
//! whose stale_after has elapsed, fed :now via the {now} clock primitive), and
//! the EXISTING worker_died_reclaim cascade reclaims the dead worker's lease and
//! expires its claim — returning the story to the pool. Proves the whole chain :
//! Tick -> Stale sweep -> MarkDead -> WorkerDied -> Reclaim + Expire, AND that a
//! fresh worker's holds are left untouched (the sweep is selective).
//!
//! Determinism without HECKS_NOW : stale_after is a far-PAST literal for the
//! dead worker and a far-FUTURE literal for the live one, so the `< now`
//! comparison is exact for any real wall-clock between 2000 and 2999. This keeps
//! the test free of the process-global HECKS_NOW env race across parallel threads.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}
fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}
fn field(rt: &Runtime, ctx: &str, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some(ctx), agg).into_iter().find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}
const LIVENESS_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/liveness_sweep.hecksagon");
const RECLAIM_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/worker_died_reclaim.hecksagon");

const PAST: &str = "2000-01-01T00:00:00Z";   // always < now
const FUTURE: &str = "2999-12-31T00:00:00Z"; // always > now

#[test]
fn tick_sweeps_the_stale_worker_and_leaves_the_fresh_one_untouched() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![
        hecksagon_parser::parse(LIVENESS_HEX),
        hecksagon_parser::parse(RECLAIM_HEX),
    ]);

    // Story sd held by a STALE worker ; story sf held by a FRESH worker.
    for r in ["sd", "sf"] {
        rt.dispatch("Plan::Story.Capture", attrs(&[
            ("ref", s(r)), ("title", s(r)), ("tier", s("1")),
            ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    }
    // STALE worker dead1 holds a Claim + Lease on sd.
    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("dead1")), ("stale_after", s(PAST))])).unwrap();
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("sd")), ("worker", s("dead1")), ("claimed_at", s("t0"))])).unwrap();
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("worktrees/sd")), ("story", s("sd")),
        ("worker", s("dead1")), ("expires_at", s(PAST))])).unwrap();
    // FRESH worker alive1 holds a Claim + Lease on sf — must survive the sweep.
    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("alive1")), ("stale_after", s(FUTURE))])).unwrap();
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("sf")), ("worker", s("alive1")), ("claimed_at", s("t0"))])).unwrap();
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("worktrees/sf")), ("story", s("sf")),
        ("worker", s("alive1")), ("expires_at", s(FUTURE))])).unwrap();

    // Pre-conditions : both workers alive, both leases active, both claims held.
    assert_eq!(field(&rt, "Conductor", "Worker", "dead1", "status").as_deref(), Some("alive"));
    assert_eq!(field(&rt, "Conductor", "Worker", "alive1", "status").as_deref(), Some("alive"));
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/sd", "state").as_deref(), Some("active"));
    assert_eq!(field(&rt, "Conductor", "Claim", "sd", "state").as_deref(), Some("held"));

    // Fire one liveness beat.
    rt.dispatch("Conductor::Sweeper.Tick", attrs(&[("sweeper_id", s("sweeper"))])).unwrap();

    // The stale worker is dead ; the fresh one untouched.
    assert_eq!(field(&rt, "Conductor", "Worker", "dead1", "status").as_deref(), Some("dead"),
        "the stale worker (stale_after in the past) must be MarkDead'd by the sweep");
    assert_eq!(field(&rt, "Conductor", "Worker", "alive1", "status").as_deref(), Some("alive"),
        "the fresh worker (stale_after in the future) must NOT be swept");

    // The dead worker's holds were reclaimed by the existing SEAM-3 cascade.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/sd", "state").as_deref(), Some("reclaimed"),
        "MarkDead -> worker_died_reclaim must reclaim the dead worker's lease");
    assert_eq!(field(&rt, "Conductor", "Claim", "sd", "state").as_deref(), Some("expired"),
        "MarkDead -> worker_died_reclaim must expire the dead worker's claim -> story re-claimable");

    // The fresh worker's holds are intact — the sweep is selective, not a flush.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/sf", "state").as_deref(), Some("active"),
        "the fresh worker's lease must remain active");
    assert_eq!(field(&rt, "Conductor", "Claim", "sf", "state").as_deref(), Some("held"),
        "the fresh worker's claim must remain held");
}
