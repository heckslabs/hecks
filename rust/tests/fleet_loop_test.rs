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

#[test]
fn two_workers_one_story_only_one_claims_the_cascade_mutex() {
    // The load-bearing invariant of the pull loop : when more workers register
    // than there is claimable work, AT MOST ONE may claim a given story. This is
    // NOT the unit mutex (Claim.Acquire's `given state != held`, covered in
    // claim.behaviors) — it is the CASCADE mutex : NextClaimable's
    // `where ref: { none_in_state: "Claim:held" }` must exclude the
    // already-claimed story so the second worker's self-claim fans over an EMPTY
    // set and never even attempts Acquire. A regression here double-claims one
    // story to two workers — the worst corruption the fleet can produce.
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![
        hecksagon_parser::parse(CLAIM_NEXT_HEX),
        hecksagon_parser::parse(VOLUNTEER_PULL_HEX),
        hecksagon_parser::parse(WORKTREE_SYNC_HEX),
    ]);

    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("1")), ("goal", s("fleet")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[
        ("sprint", s("1")), ("contracts", s("agreed"))])).unwrap();
    // EXACTLY ONE claimable story.
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("s1")), ("title", s("S1")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[
        ("story", s("s1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s("s1"))])).unwrap();

    // TWO workers join. Each fires ClaimNextOnWorkerRegistered.
    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("w1")), ("stale_after", s(FUTURE))])).unwrap();
    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("w2")), ("stale_after", s(FUTURE))])).unwrap();

    // EXACTLY ONE claim exists on s1, held by ONE worker.
    let holder = field(&rt, "Conductor", "Claim", "s1", "worker");
    assert_eq!(field(&rt, "Conductor", "Claim", "s1", "state").as_deref(), Some("held"),
        "the one story must be claimed exactly once");
    assert!(holder.as_deref() == Some("w1") || holder.as_deref() == Some("w2"),
        "the claim must be held by one of the two workers, got {:?}", holder);

    // The TOTAL number of held claims across the fleet is exactly one — the second
    // worker fanned over an empty NextClaimable and produced no claim.
    let held: Vec<_> = rt.all_qualified(Some("Conductor"), "Claim").into_iter()
        .filter(|r| r.fields.get("state").map(|v| v.to_string()).as_deref() == Some("held"))
        .collect();
    assert_eq!(held.len(), 1,
        "exactly one held claim must exist in the whole fleet, found {}", held.len());

    // Exactly one lease was granted (the winner's), not two.
    let leases: Vec<_> = rt.all_qualified(Some("Conductor"), "Lease").into_iter()
        .filter(|r| r.fields.get("state").map(|v| v.to_string()).as_deref() == Some("active"))
        .collect();
    assert_eq!(leases.len(), 1,
        "exactly one worktree lease must be granted, found {}", leases.len());
}

#[test]
fn a_story_with_an_unresolved_dependency_is_never_pull_claimed() {
    // Dependency-blocking must hold on the CASCADE path, not just the query : a
    // registering worker's self-claim fans over NextClaimable, which carries
    // `where dependencies: { resolved: true }`. The blocked story is named
    // "a_blk" so it sorts BEFORE the dependency "z_dep" under order_by :ref — if
    // the dependency filter were broken, the worker would grab "a_blk" first.
    // Claiming a story whose prerequisite is unfinished = work started out of
    // order = exactly what the DAG exists to prevent.
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![
        hecksagon_parser::parse(CLAIM_NEXT_HEX),
        hecksagon_parser::parse(VOLUNTEER_PULL_HEX),
        hecksagon_parser::parse(WORKTREE_SYNC_HEX),
    ]);

    rt.dispatch("Plan::Sprint.Plan", attrs(&[
        ("number", s("1")), ("goal", s("fleet")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[
        ("sprint", s("1")), ("contracts", s("agreed"))])).unwrap();

    // z_dep : unblocked, tasked, claimable.
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("z_dep")), ("title", s("Z")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s("z_dep")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s("z_dep"))])).unwrap();

    // a_blk : tasked but depends_on z_dep (unresolved) — sorts first, must be skipped.
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("a_blk")), ("title", s("A")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("story", s("a_blk")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s("a_blk"))])).unwrap();
    rt.dispatch("Plan::Story.AddDependency", attrs(&[("story", s("a_blk")), ("dependency", s("z_dep"))])).unwrap();

    rt.dispatch("Conductor::Worker.Register", attrs(&[
        ("worker_id", s("w1")), ("stale_after", s(FUTURE))])).unwrap();

    // The worker claimed the UNBLOCKED dependency, NOT the blocked dependent.
    assert_eq!(field(&rt, "Conductor", "Claim", "z_dep", "state").as_deref(), Some("held"),
        "the unblocked story must be claimed");
    assert!(field(&rt, "Conductor", "Claim", "a_blk", "state").is_none(),
        "the story with an unresolved dependency must NEVER be pull-claimed");
}
