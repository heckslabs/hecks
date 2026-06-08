//! Lease-TTL expiry sweep end-to-end — the worktree-leak guard.
//!
//! The lease-side twin of liveness_sweep_test. A Sweeper.Tick fans Lease.Expire
//! out over Lease.PastTtl (active leases whose expires_at has elapsed, fed :now
//! via the {now} clock primitive), and the EXISTING ReclaimOnExpire cascade
//! reclaims each expired lease's worktree path — returning it to the pool EVEN
//! WHEN THE OWNING WORKER IS STILL ALIVE. That independence from worker liveness
//! is the whole point : liveness_sweep reclaims on worker death ; this reclaims
//! on lease TTL, so a heartbeating worker that holds a worktree far too long no
//! longer leaks it forever.
//!
//! Proves the chain : Tick -> Ticked -> (ExpirySweep) Lease.Expire over
//! Lease.PastTtl -> LeaseExpired -> (ReclaimOnExpire) Lease.Reclaim. A FRESH
//! lease (TTL in the future) is left active — the sweep is selective.
//!
//! Determinism without HECKS_NOW : expires_at is a far-PAST literal for the
//! stale lease and a far-FUTURE literal for the fresh one, so the `< now`
//! comparison is exact for any real wall-clock between 2000 and 2999.

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
const EXPIRY_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/expiry_sweep.hecksagon");
const RECLAIM_ON_EXPIRE_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/reclaim_on_expire.hecksagon");

const PAST: &str = "2000-01-01T00:00:00Z";   // always < now
const FUTURE: &str = "2999-12-31T00:00:00Z"; // always > now

#[test]
fn tick_expires_the_stale_lease_and_leaves_the_fresh_one_active() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![
        hecksagon_parser::parse(EXPIRY_HEX),
        hecksagon_parser::parse(RECLAIM_ON_EXPIRE_HEX),
    ]);

    // A STALE lease (TTL in the past) and a FRESH lease (TTL in the future),
    // both active, both held by still-alive workers (no worker death involved).
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("worktrees/stale")), ("story", s("s1")),
        ("worker", s("w1")), ("expires_at", s(PAST))])).unwrap();
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("worktrees/fresh")), ("story", s("s2")),
        ("worker", s("w2")), ("expires_at", s(FUTURE))])).unwrap();

    // Pre-conditions : both active.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/stale", "state").as_deref(), Some("active"));
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/fresh", "state").as_deref(), Some("active"));

    // Fire one cadence beat.
    rt.dispatch("Conductor::Sweeper.Tick", attrs(&[("sweeper_id", s("sweeper"))])).unwrap();

    // The stale lease was expired by the sweep and reclaimed by the cascade ;
    // its worktree path is back in the pool.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/stale", "state").as_deref(), Some("reclaimed"),
        "Tick -> ExpirySweep -> Lease.Expire -> ReclaimOnExpire must reclaim the past-TTL lease");
    // The fresh lease is untouched — the sweep is selective.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/fresh", "state").as_deref(), Some("active"),
        "a lease whose TTL is still in the future must NOT be swept");
}
