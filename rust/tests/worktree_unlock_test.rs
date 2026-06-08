//! worktree-unlock — the belongs_to-on-event dividend.
//!
//! Lease belongs_to Story ; belongs_to-on-event rides the stored {story} FK on
//! LeaseReclaimed. So the StoryWorktreeSync UnlockAdapter can fire
//! Story.UnlockWorktree on reclaim — the seam the sync hecksagon's own comment
//! said it was waiting for. Proves : Grant -> LockWorktree (locked) ; Reclaim ->
//! UnlockWorktree (unlocked), driven purely by the FK riding the reclaim event.

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
const SYNC_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/conductor/hecksagons/story_worktree_sync.hecksagon"
);

#[test]
fn reclaiming_a_lease_unlocks_the_story_worktree() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(
        domain, None, vec![hecksagon_parser::parse(SYNC_HEX)]);

    // A story exists (worktree_locked defaults false).
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("s1")), ("title", s("s1")), ("tier", s("1")),
        ("summary", s("x")), ("target", s("y")), ("project", s("plan"))])).unwrap();

    // Grant a lease for s1 -> LeaseGranted -> LockAdapter -> LockWorktree(s1).
    rt.dispatch("Conductor::Lease.Grant", attrs(&[
        ("worktree_path", s("worktrees/s1")), ("story", s("s1")),
        ("worker", s("w")), ("expires_at", s("t0"))])).unwrap();
    assert_eq!(field(&rt, "Plan", "Story", "s1", "worktree_locked").as_deref(), Some("true"),
        "LeaseGranted must lock the story worktree (the lock seam already worked)");

    // Reclaim the lease. belongs_to-on-event rides story=s1 on LeaseReclaimed ->
    // UnlockAdapter -> Story.UnlockWorktree(s1) -> worktree_locked=false.
    rt.dispatch("Conductor::Lease.Reclaim", attrs(&[("id", s("worktrees/s1"))])).unwrap();
    assert_eq!(field(&rt, "Conductor", "Lease", "worktrees/s1", "state").as_deref(), Some("reclaimed"),
        "the lease is reclaimed");
    assert_eq!(field(&rt, "Plan", "Story", "s1", "worktree_locked").as_deref(), Some("false"),
        "RECLAIM must UNLOCK the story worktree — belongs_to-on-event carried the story FK on LeaseReclaimed");
}
