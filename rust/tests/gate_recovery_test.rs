//! Deploy-floor recovery : HECKS_GOVERNANCE_OFF stands the dispatch gates down
//! (NOT an in-gate backdoor — requires deploy/env access, the physical floor).
//! In its OWN test binary (separate process) so the env var never leaks into
//! other test files. One test only, so no intra-file parallelism either.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}
fn as_agent(auth: &str, extra: &[(&str, &str)]) -> HashMap<String, Value> {
    let mut m = a(extra);
    m.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    m.insert("actor_auth_id".to_string(), Value::Str(auth.to_string()));
    m
}

const GATING: &str =
    include_str!("../../hecks_conception/aggregates/language/grammar/gating.bluebook");
const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

#[test]
fn governance_off_stands_the_gates_down() {
    std::env::set_var("HECKS_GOVERNANCE_OFF", "1");
    let mut domain = parser::parse(GATING);
    domain.aggregates.extend(parser::parse(AUTHZ).aggregates);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    // Turn the PDP gate ON (deny-by-default) with NO permit for alice.
    rt.dispatch(
        "Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    )
    .expect("declare authorize gate");
    // Without the escape, deny-by-default blocks alice (proven in authorize_pdp_test).
    // With HECKS_GOVERNANCE_OFF the deploy floor admits her — recovery, not backdoor.
    rt.dispatch("Open", as_agent("alice", &[("name", "v1")]))
        .expect("HECKS_GOVERNANCE_OFF should stand the dispatch gates down");
    std::env::remove_var("HECKS_GOVERNANCE_OFF");
}
