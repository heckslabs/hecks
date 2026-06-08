//! references-not-ids SEAM 3 — worker-died reclaim, end-to-end.
//!
//! Boots the REAL Conductor domain (Lease + Claim + Worker, loaded from
//! hecks_conception via load_combined_domain so Conductor::-qualified FQNs
//! resolve exactly as production) plus the REAL worker_died_reclaim.hecksagon.
//! A genuine Worker.MarkDead dispatch emits WorkerDied ; the ReclaimOnWorkerDied
//! driven adapter sweeps Lease.HeldByWorker / Claim.HeldByWorker (where worker ==
//! the dead worker_id, fed by {id} = the event aggregate_id) and fires
//! Lease.Reclaim / Claim.Expire once per matched record. The stored worker FK
//! (synthesised by belongs_to Worker — references-not-ids phases 1-2) is what
//! makes the where match ; no back-ref on Worker.
//!
//! Test 1 seeds leases/claims DIRECTLY (Grant/Acquire with worker set) and
//! asserts the dead worker's are reclaimed/expired while a second worker's are
//! untouched. Test 2 exercises the FULL production chain : Claim.Acquire ->
//! (volunteer_pull SEAM 2) Lease.Grant carrying the worker FK off the
//! ClaimAcquired event -> MarkDead -> SEAM 3 reclaim. This is the regression
//! guard for the SEAM-2-must-carry-worker bug. Driven adapters fire only on
//! REAL command events, so MarkDead/Acquire are real rt.dispatch calls.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const RECLAIM_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/worker_died_reclaim.hecksagon"
);
const VOLUNTEER_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/volunteer_pull.hecksagon"
);

fn conductor_dir() -> String {
    format!("{}/../hecks_conception/aggregates/conductor", env!("CARGO_MANIFEST_DIR"))
}

fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("Conductor"), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

fn boot(hexes: &[&str]) -> Runtime {
    let domain = load_combined_domain(&conductor_dir());
    let parsed: Vec<_> = hexes.iter().map(|h| hecksagon_parser::parse(h)).collect();
    Runtime::boot_with_hecksagons(domain, None, parsed)
}

// Full corpus (Plan + Conductor) — needed since the SEAM-2 split made Lease.Grant
// fire on Plan::Story.StoryStarted (not Conductor::Claim.ClaimAcquired), so the
// grant lands only once a REAL Story.Start succeeds. conductor_dir() alone can no
// longer reach a granted lease through the cascade.
fn full_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}
fn boot_full(hexes: &[&str]) -> Runtime {
    let domain = load_combined_domain(&full_dir());
    let parsed: Vec<_> = hexes.iter().map(|h| hecksagon_parser::parse(h)).collect();
    Runtime::boot_with_hecksagons(domain, None, parsed)
}
fn ratified_sprint(rt: &mut Runtime, number: &str) {
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s(number)), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[
        ("id", s(number)), ("contracts", s("c"))])).unwrap();
}
// Capture + assign to the ratified sprint + Task -> state=tasked, Start-ready.
fn tasked_story(rt: &mut Runtime, ref_: &str, sprint: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(ref_)), ("title", s(ref_)), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("id", s(ref_)), ("sprint_ref", s(sprint))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s(ref_))])).unwrap();
}

#[test]
fn worker_death_reclaims_only_its_own_lease_and_claim() {
    let mut rt = boot(&[RECLAIM_HECKSAGON]);

    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("W")), ("heartbeat_at", s("t0"))])).unwrap();
    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("keeper")), ("heartbeat_at", s("t0"))])).unwrap();

    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("wt/W")), ("story", s("sW")),
        ("worker", s("W")), ("expires_at", s("t0"))])).unwrap();
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("wt/keeper")), ("story", s("sK")),
        ("worker", s("keeper")), ("expires_at", s("t0"))])).unwrap();

    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("cW")), ("worker", s("W")), ("claimed_at", s("t0"))])).unwrap();
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("cK")), ("worker", s("keeper")), ("claimed_at", s("t0"))])).unwrap();

    assert_eq!(field(&rt, "Lease", "wt/W", "state").as_deref(), Some("active"));
    assert_eq!(field(&rt, "Lease", "wt/keeper", "state").as_deref(), Some("active"));
    assert_eq!(field(&rt, "Claim", "cW", "state").as_deref(), Some("held"));
    assert_eq!(field(&rt, "Claim", "cK", "state").as_deref(), Some("held"));

    // REAL dispatch : MarkDead -> WorkerDied -> ReclaimOnWorkerDied fan-out.
    rt.dispatch("Conductor::Worker.MarkDead", attrs(&[("id", s("W"))])).unwrap();

    assert_eq!(field(&rt, "Lease", "wt/W", "state").as_deref(), Some("reclaimed"),
        "dead worker W's lease must be reclaimed");
    assert_eq!(field(&rt, "Claim", "cW", "state").as_deref(), Some("expired"),
        "dead worker W's claim must be expired");
    assert_eq!(field(&rt, "Lease", "wt/keeper", "state").as_deref(), Some("active"),
        "keeper's lease must be untouched");
    assert_eq!(field(&rt, "Claim", "cK", "state").as_deref(), Some("held"),
        "keeper's claim must be untouched");
}

#[test]
fn seam2_claim_acquired_grants_lease_with_worker_fk_then_seam3_reclaims_it() {
    // Full production chain under the SEAM-2 SPLIT : Claim.Acquire -> (SEAM 2a)
    // Story.Start -> StoryStarted -> (SEAM 2b) Lease.Grant carrying the worker FK
    // -> MarkDead -> (SEAM 3) reclaim. The split made Grant CONDITIONAL on a real
    // StoryStarted, so this test now loads the FULL corpus (Plan + Conductor) and
    // seeds story42 as a genuinely Start-ready story (ratified sprint + tasked).
    // If Start were refused, no StoryStarted fires and the lease never grants —
    // which is exactly the safety the split buys.
    let mut rt = boot_full(&[VOLUNTEER_HECKSAGON, RECLAIM_HECKSAGON]);
    ratified_sprint(&mut rt, "1");
    tasked_story(&mut rt, "story42", "1");

    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("W2")), ("heartbeat_at", s("t0"))])).unwrap();

    // Acquire triggers SEAM 2a (Start story42) -> StoryStarted -> SEAM 2b
    // Lease.Grant(worktree_path: worktrees/story42, story: story42, worker: W2).
    // The worker FK flowing all the way through the split is the regression-guarded
    // bit.
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("story42")), ("worker", s("W2")), ("claimed_at", s("t0"))])).unwrap();

    // story42 actually started (SEAM 2a gate passed) and only THEN was the lease
    // granted (SEAM 2b), carrying worker = W2 (the FK that makes SEAM 3 findable).
    assert_eq!(field_in(&rt, "Plan", "Story", "story42", "state").as_deref(), Some("started"),
        "SEAM 2a : story42 must Start before any lease is granted");
    assert_eq!(field(&rt, "Lease", "worktrees/story42", "state").as_deref(), Some("active"),
        "SEAM 2b : the lease must grant AFTER StoryStarted");
    assert_eq!(field(&rt, "Lease", "worktrees/story42", "worker").as_deref(), Some("W2"),
        "SEAM 2b must carry the worker FK onto the granted lease through the split");

    // W2 dies -> SEAM 3 must reclaim the SEAM-2-granted lease + expire the claim.
    rt.dispatch("Conductor::Worker.MarkDead", attrs(&[("id", s("W2"))])).unwrap();

    assert_eq!(field(&rt, "Lease", "worktrees/story42", "state").as_deref(), Some("reclaimed"),
        "SEAM 3 must reclaim the lease SEAM 2 granted (worker FK flowed through)");
    assert_eq!(field(&rt, "Claim", "story42", "state").as_deref(), Some("expired"),
        "SEAM 3 must expire the dead worker's claim");
}

// Cross-context record lookup (the shared `field` helper is Conductor-only).
fn field_in(rt: &Runtime, ctx: &str, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some(ctx), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}
