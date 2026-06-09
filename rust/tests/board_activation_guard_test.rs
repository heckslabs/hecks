//! Board RULE #4 : only a sprint placed on the board may be activated.
//!
//! ActivateSprint carries given { queued_sprints.include?(sprint_ref) } — a
//! LOCAL list-membership predicate : the activated sprint must already be in
//! the board's own queued_sprints list (put there by PlaceSprint). Activating a
//! sprint that was never placed is a planning-integrity violation.

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
    rt.all_qualified(Some("Plan"), agg).into_iter().find(|r| r.id == id)
        .and_then(|r| r.fields.get(f).map(|v| v.to_string()))
}

#[test]
fn activate_sprint_is_gated_on_board_membership() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    rt.dispatch("Plan::Board.Open", attrs(&[("name", s("bd")), ("project", s("plan"))])).unwrap();
    rt.dispatch("Plan::Board.PlaceSprint", attrs(&[("board", s("bd")), ("sprint_ref", s("s1"))])).unwrap();

    // s2 was never placed on the board — activation MUST be refused.
    let refused = rt.dispatch("Plan::Board.ActivateSprint", attrs(&[
        ("board", s("bd")), ("sprint_ref", s("s2")),
        ("active_sprints", Value::List(vec![s("s2")]))]));
    assert!(refused.is_err(),
        "activating a sprint not on the board must be refused, got: {:?}", refused);

    // s1 IS on the board — activation succeeds.
    rt.dispatch("Plan::Board.ActivateSprint", attrs(&[
        ("board", s("bd")), ("sprint_ref", s("s1")),
        ("active_sprints", Value::List(vec![s("s1")]))])).unwrap();
    // The unwrap above already proves s1 activated (a false-refusal would panic) ;
    // confirm the active set is now a one-element list (rendered "[1 items]").
    assert_eq!(field(&rt, "Board", "bd", "active_sprints").as_deref(), Some("[1 items]"),
        "a placed sprint must activate and populate the active set");
}
