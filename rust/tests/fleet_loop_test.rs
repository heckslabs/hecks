//! Fleet loop end-to-end : ONE Worker.Register drives the whole pull chain.
//!
//! This is the capstone gate over the seams landed across the sprint :
//! where-fan-out (SEAM 1), the ClaimAcquired->Start->Grant cascade (SEAM 2),
//! the worktree lock, and the {now} clock primitive (claimed_at / expires_at).
//! It proves they COMPOSE — not that each works in isolation (the per-aggregate
//! behaviors already cover that), but that a single trigger walks the entire
//! loop with no human in between :
//!
//!   Conductor::Worker.Register
//!     -> WorkerRegistered
//!     -> (ClaimNextOnWorkerRegistered) fan Claim.Acquire over Plan::Story.NextClaimable   [SEAM 1]
//!     -> ClaimAcquired
//!     -> (StartOnClaimAcquired) Plan::Story.Start                                          [SEAM 2]
//!     -> StoryStarted
//!     -> (GrantOnStoryStarted) Conductor::Lease.Grant worktrees/{story} expires {now+3600}
//!     -> LeaseGranted
//!     -> (LockAdapter) Plan::Story.LockWorktree
//!
//! The story is seeded fully claimable AND fully startable : on a sprint whose
//! contracts are ratified (Story.Start's cross-aggregate POINT gate), tasked,
//! no unresolved dependencies, no held claim. That setup is the real release
//! shape — the contract-first front-bookend has to be satisfied for the loop to
//! complete, so this test also proves the gate composes with the fleet pull.
//!
//! The impure git adapters (WorktreeCreate / WorktreeRemove, driven on the same
//! LeaseGranted/Reclaimed events) are deliberately NOT loaded : they run real
//! `git worktree add` and belong to their own binding test. This gate is the
//! DOMAIN loop — pure, fast, deterministic. stale_after is a far-future literal
//! so the registered worker never trips a liveness sweep mid-test.

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

// The DOMAIN-cascade adapters — the impure git pair is intentionally omitted.
const CLAIM_NEXT_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/claim_next_on_worker_registered.hecksagon");
const VOLUNTEER_PULL_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/volunteer_pull.hecksagon");
const WORKTREE_SYNC_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/story_worktree_sync.hecksagon");

const FUTURE: &str = "2999-12-31T00:00:00Z"; // worker stays alive for the whole test

#[test]
fn one_worker_register_pulls_claims_starts_and_leases_a_story() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![
        hecksagon_parser::parse(CLAIM_NEXT_HEX),
        hecksagon_parser::parse(VOLUNTEER_PULL_HEX),
        hecksagon_parser::parse(WORKTREE_SYNC_HEX),
    ]);

    // A sprint with ratified contracts — the front-bookend Story.Start gates on.
    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("1")), ("goal", s("fleet")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[
        ("sprint", s("1")), ("contracts", s("agreed"))])).unwrap();

    // A story : captured, put on the ratified sprint, tasked — now claimable AND startable.
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("s1")), ("title", s("S1")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("story", s("s1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s("s1"))])).unwrap();

    // Pre-conditions : nothing claimed, story not yet started, no lease.
    assert_eq!(field(&rt, "Plan", "Story", "s1", "state").as_deref(), Some("tasked"));
    assert!(field(&rt, "Conductor", "Claim", "s1", "state").is_none(),
        "no claim should exist before any worker registers");

    // THE SINGLE TRIGGER : a worker joins the fleet. Everything else cascades.
    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("w1")), ("stale_after", s(FUTURE))])).unwrap();

    // SEAM 1 : the worker self-claimed the one claimable story.
    assert_eq!(field(&rt, "Conductor", "Claim", "s1", "state").as_deref(), Some("held"),
        "Worker.Register must fan Claim.Acquire over NextClaimable and hold the story");
    assert_eq!(field(&rt, "Conductor", "Claim", "s1", "worker").as_deref(), Some("w1"),
        "the claim must be held by the registering worker");

    // SEAM 2 : the claim started the story.
    assert_eq!(field(&rt, "Plan", "Story", "s1", "state").as_deref(), Some("started"),
        "ClaimAcquired must drive Story.Start through the contract-ratified gate");

    // SEAM 2 cont. : starting granted a worktree lease, bound to the worker.
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/s1", "state").as_deref(), Some("active"),
        "StoryStarted must grant a Lease on worktrees/{{story}}");
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/s1", "worker").as_deref(), Some("w1"),
        "the lease must belong to the worker that started the story");

    // The worktree lock landed on the story (LeaseGranted -> LockWorktree).
    assert_eq!(field(&rt, "Plan", "Story", "s1", "worktree_locked").as_deref(), Some("true"),
        "LeaseGranted must lock the story's worktree");
}
