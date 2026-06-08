//! SEAM 1 — worker self-select "next claimable story", end-to-end.
//!
//! Boots the REAL Plan + Conductor domains (full corpus via
//! load_combined_domain so Plan::Story.* and Conductor::Claim.* FQNs resolve
//! exactly as production) plus the REAL claim_next_on_worker_registered.hecksagon
//! and volunteer_pull.hecksagon.
//!
//! A genuine Worker.Register emits WorkerRegistered ; the
//! ClaimNextOnWorkerRegistered driven adapter sweeps Plan::Story.NextClaimable
//! (state tasked + deps resolved + NO held Claim, the WhereOp::NoneInState
//! anti-join) and fires Conductor::Claim.Acquire once for the picked story
//! (story: {ref} record-first ; worker: {worker_id} from event.data). The
//! ClaimAcquired then cascades volunteer_pull SEAM 2a (Start) -> 2b (Grant).
//!
//! Driven adapters fire only on REAL command events, so every Register /
//! lifecycle dispatch below is a real rt.dispatch.
//!
//! Proves : the UNCLAIMED claimable story gets a held Claim for the worker AND
//! starts AND gets a worktree lease carrying the worker FK ; an already-held
//! story does NOT get a second claim (NextClaimable's none_in_state excludes
//! it) ; an untasked / dependency-blocked story is never claimed.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const CLAIM_NEXT_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/claim_next_on_worker_registered.hecksagon"
);
const VOLUNTEER_HECKSAGON: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/volunteer_pull.hecksagon"
);

fn aggregates_dir() -> String {
    format!("{}/../hecks_conception/aggregates", env!("CARGO_MANIFEST_DIR"))
}

fn field(rt: &Runtime, ctx: &str, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some(ctx), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

fn claim_count(rt: &Runtime) -> usize {
    rt.all_qualified(Some("Conductor"), "Claim").len()
}

fn boot() -> Runtime {
    let domain = load_combined_domain(&aggregates_dir());
    let hexes = vec![
        hecksagon_parser::parse(CLAIM_NEXT_HECKSAGON),
        hecksagon_parser::parse(VOLUNTEER_HECKSAGON),
    ];
    Runtime::boot_with_hecksagons(domain, None, hexes)
}

// Drive a Sprint to planned + contracts-ratified (Start's ratify gate).
fn ratified_sprint(rt: &mut Runtime, number: &str) {
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s(number)), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[
        ("id", s(number)), ("contracts", s("c"))])).unwrap();
}

// Capture a Story, put it on the ratified sprint, and Task it (no deps -> the
// dependency set is empty -> resolved). Leaves it state=tasked, Start-ready.
fn tasked_story(rt: &mut Runtime, ref_: &str, sprint: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(ref_)), ("title", s(ref_)), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("id", s(ref_)), ("sprint_ref", s(sprint))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s(ref_))])).unwrap();
}

// Capture + Task a Story but DO NOT assign it to a sprint. It reaches
// state=tasked (Tasked only needs state==untasked), yet Story.Start would
// REFUSE it (gate `sprint != ""`). So when its Claim is acquired, the SEAM 2a
// cascade-Start is refused and the story STAYS tasked -> it remains a
// NextClaimable candidate, excludable ONLY by none_in_state. This is what
// makes test #1 discriminate the predicate (a held-but-still-tasked story).
fn tasked_story_no_sprint(rt: &mut Runtime, ref_: &str) {
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s(ref_)), ("title", s(ref_)), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s(ref_))])).unwrap();
}

#[test]
fn worker_registration_claims_starts_and_leases_the_next_unheld_story() {
    let mut rt = boot();
    ratified_sprint(&mut rt, "1");

    // Register "other" BEFORE any story is claimable. SEAM 1 fires on EVERY real
    // Worker.Register, so we register "other" while NextClaimable is empty -> no
    // accidental auto-claim. The only held Claim is the explicit one below.
    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("other"))])).unwrap();

    // "aaa" : tasked but SPRINTLESS. Sorts first ; stays tasked even after its
    // Claim is acquired (its cascade-Start is refused on `sprint != ""`), so it
    // remains a NextClaimable candidate that ONLY none_in_state can exclude.
    // "bbb" : fully Start-ready on the ratified sprint.
    tasked_story_no_sprint(&mut rt, "aaa");
    tasked_story(&mut rt, "bbb", "1");

    // Pre-claim "aaa" (held, keyed by story=aaa) by "other".
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("aaa")), ("worker", s("other")), ("claimed_at", s("t0"))])).unwrap();

    // DISCRIMINATION GUARD : aaa is held BUT still tasked (its cascade-Start was
    // refused). So `where state: tasked` does NOT exclude it ; the held "aaa" is
    // excluded from NextClaimable SOLELY by `where ref: { none_in_state:
    // "Claim:held" }`. Disable that predicate and this test must fail (aaa sorts
    // first, order_by+limit-1 picks it, Acquire refuses it, bbb never claimed).
    assert_eq!(field(&rt, "Plan", "Story", "aaa", "state").as_deref(), Some("tasked"),
        "setup invariant : aaa must remain tasked (sprintless Start refused), so \
         none_in_state is the SOLE excluder — the predicate's discrimination guard");

    let claims_before = claim_count(&rt);

    // REAL Register for a NEW worker -> SEAM 1 self-select fires.
    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("newbie"))])).unwrap();

    for c in rt.all_qualified(Some("Conductor"), "Claim") {
        eprintln!("CLAIM id={} story={:?} worker={:?} state={:?}", c.id,
            c.fields.get("story").map(|v| v.to_string()),
            c.fields.get("worker").map(|v| v.to_string()),
            c.fields.get("state").map(|v| v.to_string()));
    }
    // none_in_state excluded the held "aaa" -> picked "bbb". bbb got a held Claim.
    assert_eq!(field(&rt, "Conductor", "Claim", "bbb", "state").as_deref(), Some("held"),
        "the unheld claimable story bbb must get a held Claim");
    assert_eq!(field(&rt, "Conductor", "Claim", "bbb", "worker").as_deref(), Some("newbie"),
        "bbb's Claim must record the registering worker");

    // Exactly ONE new Claim (no second claim on aaa).
    assert_eq!(claim_count(&rt), claims_before + 1,
        "exactly one new Claim (bbb) ; aaa must NOT get a second claim");
    assert_eq!(field(&rt, "Conductor", "Claim", "aaa", "worker").as_deref(), Some("other"),
        "aaa's existing Claim must stay with 'other' (none_in_state excluded it)");

    // SEAM 2 split : ClaimAcquired -> Start (bbb starts) -> StoryStarted -> Grant.
    assert_eq!(field(&rt, "Plan", "Story", "bbb", "state").as_deref(), Some("started"),
        "SEAM 2a : bbb must transition to started (Start gates passed)");
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/bbb", "state").as_deref(), Some("active"),
        "SEAM 2b : a worktree lease must be granted AFTER StoryStarted");
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/bbb", "worker").as_deref(), Some("newbie"),
        "the granted lease must carry the worker FK through the split");
}

#[test]
fn an_untasked_or_dep_blocked_story_is_not_claimed() {
    let mut rt = boot();
    ratified_sprint(&mut rt, "1");

    // "draft" is Captured + assigned but NOT Tasked -> state is pre-tasked, so
    // NextClaimable's `where state: "tasked"` excludes it.
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("draft")), ("title", s("draft")), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("id", s("draft")), ("sprint_ref", s("1"))])).unwrap();

    rt.dispatch("Conductor::Worker.Register",
        attrs(&[("worker_id", s("w")), ("heartbeat_at", s("t0"))])).unwrap();

    // No claimable story -> NextClaimable empty -> zero Claims acquired.
    assert_eq!(claim_count(&rt), 0,
        "an untasked story must not be claimed (NextClaimable excludes it)");
    assert_eq!(field(&rt, "Plan", "Story", "draft", "state").as_deref().map(|s| s != "started"),
        Some(true), "the untasked story must not have started");
}

#[test]
fn claiming_an_unstartable_story_creates_no_lease() {
    // SEAM 2 cascade-order safety (the negative twin) : the worktree lease is
    // granted on StoryStarted, NOT on ClaimAcquired. So acquiring a Claim on an
    // UN-STARTABLE story (here tasked-but-sprintless, whose Start gate
    // `sprint != ""` refuses) must leave NO lease and NO worktree — the refused
    // Start short-circuits Grant. Proves the fix prevents the "real garbage
    // worktree" the old Grant-on-ClaimAcquired order caused.
    let mut rt = boot();

    // A tasked story with no sprint -> Story.Start will refuse it.
    tasked_story_no_sprint(&mut rt, "stuck");

    // Acquire a Claim directly (the dangerous case NextClaimable is meant to
    // avoid). The ungated mutex takes the claim ; the cascade then dispatches
    // Story.Start, which REFUSES on `sprint != ""`.
    rt.dispatch("Conductor::Claim.Acquire", attrs(&[
        ("story", s("stuck")), ("worker", s("w1")), ("claimed_at", s("t0"))])).unwrap();

    // The Claim is held (the mutex took)...
    assert_eq!(field(&rt, "Conductor", "Claim", "stuck", "state").as_deref(), Some("held"),
        "the ungated Acquire mutex still takes the claim");
    // ...but Start was REFUSED, so the story stayed tasked (never started)...
    assert_eq!(field(&rt, "Plan", "Story", "stuck", "state").as_deref(), Some("tasked"),
        "Story.Start must refuse the sprintless story (it stays tasked)");
    // ...and CRUCIALLY no lease / worktree was created : Grant fires only on
    // StoryStarted, which never emitted. The no-garbage guarantee.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/stuck", "state"), None,
        "NO lease may exist for an un-startable story — the cascade-order fix \
         prevents the garbage worktree (Grant never fired)");
    assert_eq!(rt.all_qualified(Some("Conductor"), "Lease").len(), 0,
        "zero Lease records — a refused Start created no worktree state");
}
