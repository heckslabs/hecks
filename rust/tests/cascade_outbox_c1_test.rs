//! Phase 3 / C1 — the persistent transactional outbox, dual-write.
//!
//! When a dispatched command's event has policy reactions, the runtime
//! ALSO writes a persistent `CascadeRun.Begin` recording those reactions
//! as ordered Steps — the outbox a later pump (C2) will drain. The eager
//! cascade still runs (body-safe); this proves the run record lands.
//!
//! CascadeRun is an aggregate, so the record persists to heki and survives
//! the production fork-per-dispatch — the reason an in-memory outbox can't
//! be the answer.
//!
//! Gated by HECKS_CASCADE_OUTBOX=1 so the live body is untouched until the
//! pump is wired. Single test in this binary — the process-global env var
//! has no cross-test race.

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
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> Option<String> {
    rt.all_qualified(Some("CascadeRun"), agg)
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

#[test]
fn runtime_dual_writes_a_persistent_cascade_run_for_a_policy_cascade() {
    std::env::set_var("HECKS_CASCADE_OUTBOX", "1");

    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot(domain);

    // Minimal setup to reach Task.Add (proven path in story_reset_test):
    // Task.Add emits TaskAdded, which the IncrementOnTaskAdded policy turns
    // into a Story pending-count bump — a real cross-aggregate policy cascade.
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("1")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("r1")), ("title", s("r1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("r1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Task.Add", attrs(&[("id", s("t1")), ("story", s("r1")), ("order", s("1")), ("description", s("d"))])).unwrap();

    // The persistent outbox now holds a CascadeRun for the TaskAdded cascade.
    let run_id = "t1::TaskAdded".to_string();
    let trigger = field(&rt, "CascadeRun", &run_id, "trigger_event");
    assert_eq!(trigger.as_deref(), Some("TaskAdded"),
        "runtime wrote a persistent CascadeRun for the TaskAdded policy cascade; got runs: {:?}",
        rt.all_qualified(Some("CascadeRun"), "CascadeRun").into_iter().map(|r| r.id.clone()).collect::<Vec<_>>());

    // The run is queryable as Active (status running) and carries steps.
    let status = field(&rt, "CascadeRun", &run_id, "status");
    assert_eq!(status.as_deref(), Some("running"), "new run starts running (Active)");
    let steps = field(&rt, "CascadeRun", &run_id, "steps");
    assert_eq!(steps.as_deref(), Some("[1 items]"), "one planned step (the IncrementOnTaskAdded trigger)");
}
