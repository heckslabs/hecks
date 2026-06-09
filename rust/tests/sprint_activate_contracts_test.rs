//! Sprint.Activate is gated INTRA-Sprint on contracts_ratified (the consolidation that
//! lets Story.Start drop its cross-aggregate contracts read — sprint_active implies
//! ratified, since a sprint cannot activate without ratified contracts). Runtime-level
//! test : the behaviors runner's shared-state/dispatch_isolated path is flaky for this
//! command-refusal shape, but the runtime itself enforces it deterministically.

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

#[test]
fn activate_refused_until_contracts_ratified() {
    let domain = load_combined_domain(&aggregates_dir());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    rt.dispatch("Plan::Sprint.Plan", attrs(&[("number", s("z9")), ("goal", s("g")), ("project", s("p"))])).unwrap();

    let refused = rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("z9"))]));
    assert!(refused.is_err(), "a planned-but-unratified sprint must refuse Activate, got {:?}", refused);

    rt.dispatch("Plan::Sprint.RatifyContracts", attrs(&[("id", s("z9")), ("contracts", s("c"))])).unwrap();
    rt.dispatch("Plan::Sprint.Activate", attrs(&[("id", s("z9"))])).unwrap();
    let active = rt.all_qualified(Some("Plan"), "Sprint").into_iter().find(|r| r.id == "z9")
        .and_then(|r| r.fields.get("state").map(|v| v.to_string()));
    assert_eq!(active.as_deref(), Some("active"), "once ratified, Activate succeeds");
}
