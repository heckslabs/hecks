//! Phase 3 / C2 — the pump drains the persistent CascadeRun outbox.
//!
//! The async seam, end to end on the persistent queue:
//!   1. dispatch_deferred runs a command's core mutation (one aggregate)
//!      and writes a CascadeRun outbox entry — but does NOT run the
//!      reaction. The sibling is unchanged.
//!   2. pump_outbox() — a SEPARATE phase (a later tick in production) —
//!      reads CascadeRun.Active and delivers each step as its own
//!      transaction, then Completes the run.
//!
//! Canonical cascade: Task.Add emits TaskAdded ; the BumpOnTaskAdded policy
//! triggers Story.BumpPendingTaskCount (pending_task_count += 1). Deferred,
//! the bump waits in the outbox ; the pump delivers it.
//!
//! Setup commands settle via `dispatch` (record + pump_outbox + complete) ;
//! the command under test uses `dispatch_deferred` so its run stays Active
//! until the explicit `pump_outbox()` below delivers it.

use storehouse::corpus_loader::load_combined_domain;
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
    rt.all_qualified(Some(ctx), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

#[test]
fn pump_outbox_delivers_a_deferred_dispatchs_reaction() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot(domain);

    // Setup settles synchronously via `dispatch` (each records to the outbox,
    // then pump_outbox drains + Completes it), so only the command under test
    // leaves an Active run.
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("1")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("r1")), ("title", s("r1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("r1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s("r1"))])).unwrap();
    assert_eq!(field(&rt, "Plan", "Story", "r1", "pending_task_count").as_deref(), Some("0"), "baseline");

    // Turn the persistent outbox on, then DEFER the cascade-triggering command.
    rt.dispatch_deferred("Plan::Task.Add", attrs(&[("id", s("t1")), ("story", s("r1")), ("order", s("1")), ("description", s("d"))])).unwrap();

    // The Task exists (core mutation, one aggregate) but the reaction is
    // DEFERRED — the bump has not run.
    assert_eq!(field(&rt, "Plan", "Task", "t1", "status").as_deref(), Some("pending"), "task created");
    assert_eq!(field(&rt, "Plan", "Story", "r1", "pending_task_count").as_deref(), Some("0"),
        "reaction DEFERRED — bump waits in the persistent outbox, not run inline");
    assert_eq!(field(&rt, "CascadeRun", "CascadeRun", "Task::t1::TaskAdded", "status").as_deref(), Some("running"),
        "outbox entry is Active, awaiting the pump");

    // Pump delivers it — a separate phase, its own transaction.
    let drained = rt.pump_outbox();
    assert_eq!(drained, 1, "one Active run drained");
    assert_eq!(field(&rt, "Plan", "Story", "r1", "pending_task_count").as_deref(), Some("1"),
        "reaction DELIVERED by the pump — bump applied as its own transaction");
    assert_eq!(field(&rt, "CascadeRun", "CascadeRun", "Task::t1::TaskAdded", "status").as_deref(), Some("completed"),
        "run Completed — leaves the Active set, never re-delivered (run-grain idempotency)");

    // Idempotency: a second pump finds nothing Active, delivers nothing.
    assert_eq!(rt.pump_outbox(), 0, "completed run is not re-pumped");
    assert_eq!(field(&rt, "Plan", "Story", "r1", "pending_task_count").as_deref(), Some("1"),
        "no double-delivery on re-pump");
}
