//! Two lifecycle invariants that the .behaviors runner can't cleanly cover
//! (ambiguous command-name setups), proven here via FQN dispatch instead.

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
fn boot() -> Runtime {
    Runtime::boot_with_hecksagons(load_combined_domain(&aggregates_dir()), None, vec![])
}

#[test]
fn project_complete_refused_from_a_terminal_state() {
    // Project.Complete : given { status active || paused }. A done project
    // cannot be completed again. (Behavior setup can't reach `done` cleanly :
    // Complete/Cancel names collide across aggregates ; FQN dispatch is exact.)
    let mut rt = boot();
    rt.dispatch("Plan::Project.Register", attrs(&[("name", s("px"))])).unwrap();
    rt.dispatch("Plan::Project.Complete", attrs(&[("id", s("px"))])).unwrap(); // active -> done
    let refused = rt.dispatch("Plan::Project.Complete", attrs(&[("id", s("px"))]));
    assert!(refused.is_err(),
        "completing an already-done project must be refused, got: {:?}", refused);
}

#[test]
fn an_unsprinted_story_cannot_start() {
    // The invariant : a story with no sprint must not Start. NOTE the gate that
    // actually catches it is `sprint contracts must be ratified`, NOT
    // `story must be on a sprint board` (sprint != "") — an UNSET sprint is Null,
    // and `Null != ""` is true, so the board gate passes and the contracts gate
    // (Sprint("").contracts_ratified == true, unresolvable) refuses first. The
    // invariant holds either way ; this asserts the fact, not a chosen message.
    let mut rt = boot();
    rt.dispatch("Plan::Story.Capture", attrs(&[
        ("ref", s("u1")), ("title", s("u")), ("tier", s("1")),
        ("summary", s("s")), ("target", s("t")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Story.Tasked", attrs(&[("story", s("u1"))])).unwrap();
    let refused = rt.dispatch("Plan::Story.Start", attrs(&[("story", s("u1"))]));
    assert!(refused.is_err(),
        "a story with no sprint must not be allowed to Start, got: {:?}", refused);
}
