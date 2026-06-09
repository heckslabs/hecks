//! Phase 3 / C3 — the outbox captures DRIVEN-ADAPTER reactions too.
//!
//! C1/C2 routed policy reactions through the persistent outbox. The body
//! also runs hecksagon `driven on` cascades ; the eager->deferred cutover
//! can't land until those are captured too, or they'd be dropped. This
//! proves a driven-adapter reaction is enumerated into the CascadeRun and
//! delivered by pump_outbox — not by the deferred dispatch.
//!
//! reset_story_tasks: `driven on StoryReset do dispatch Task.Reopen,
//! for_each: Task.ForStory`. A deferred Story.Reset reverts the Story (core,
//! one aggregate) but the task reopen waits in the outbox until the pump.

use storehouse::corpus_loader::load_combined_domain;
use storehouse::hecksagon_parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}
const RESET_HEX: &str = include_str!(
    "../../hecks_conception/aggregates/plan/hecksagons/reset_story_tasks.hecksagon"
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

#[test]
fn pump_outbox_delivers_a_driven_adapter_reaction() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hecksagon_parser::parse(RESET_HEX)]);

    // Flag-off setup: a started story with one completed task.
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("1")), ("goal", s("g")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("1")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.Capture", attrs(&[("ref", s("r1")), ("title", s("r1")), ("tier", s("1")), ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.AssignToSprint", attrs(&[("id", s("r1")), ("sprint_ref", s("1"))])).unwrap();
    rt.dispatch("Plan::Story.MarkSprintActive", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("id", s("r1"))])).unwrap();
    rt.dispatch("Plan::Task.Add", attrs(&[("id", s("t1")), ("story", s("r1")), ("order", s("1")), ("description", s("d"))])).unwrap();
    rt.dispatch("Plan::Task.Complete", attrs(&[("id", s("t1"))])).unwrap();
    rt.dispatch("Plan::Story.Start", attrs(&[("story", s("r1"))])).unwrap();
    assert_ne!(field(&rt, "Plan", "Task", "t1", "status").as_deref(), Some("pending"), "task is done pre-reset");

    // Turn the outbox on and DEFER the reset.
    std::env::set_var("HECKS_CASCADE_OUTBOX", "1");
    rt.dispatch_deferred("Plan::Story.Reset", attrs(&[("id", s("r1"))])).unwrap();

    // Core mutation (Story reverted) is synchronous — one aggregate.
    assert_eq!(field(&rt, "Plan", "Story", "r1", "state").as_deref(), Some("tasked"),
        "Story reverted by the core dispatch (single aggregate)");
    // The DRIVEN reaction (Task.Reopen) is DEFERRED — task not yet reopened.
    assert_ne!(field(&rt, "Plan", "Task", "t1", "status").as_deref(), Some("pending"),
        "driven-adapter reaction DEFERRED — task reopen waits in the outbox");

    // Pump delivers the driven-adapter step.
    let drained = rt.pump_outbox();
    assert!(drained >= 1, "at least the StoryReset run drained");
    assert_eq!(field(&rt, "Plan", "Task", "t1", "status").as_deref(), Some("pending"),
        "task REOPENED by the pump — driven-adapter reaction delivered as its own transaction");
}
