//! Behaviors dump — canonical JSON for a TestSuite (parity contract).
//!
//! Mirrors `dump.rs`. The Ruby side's `Hecks::Parity::CanonicalIR.dump_test_suite`
//! must produce identical JSON for the same source.

use crate::behaviors_ir::*;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub fn dump(suite: &TestSuite) -> Value {
    json!({
        "name":   suite.name,
        "vision": suite.vision,
        "tests":  suite.tests.iter().map(dump_test).collect::<Vec<_>>(),
    })
}

fn dump_test(t: &Test) -> Value {
    json!({
        "description":    t.description,
        "tests_command":  t.tests_command,
        "on_aggregate":   t.on_aggregate,
        "kind":           t.kind,
        "setups":         t.setups.iter().map(dump_setup).collect::<Vec<_>>(),
        "input":          dump_args(&t.input),
        "expect":         dump_args(&t.expect),
    })
}

fn dump_setup(s: &TestSetup) -> Value {
    json!({
        "command": s.command,
        "args":    dump_args(&s.args),
    })
}

/// Args/expects/inputs render as ordered [key, value] pairs — same shape
/// the fixture dump uses, so order is stable across both parsers.
fn dump_args(m: &BTreeMap<String, String>) -> Value {
    let pairs: Vec<Value> = m.iter().map(|(k, v)| json!([k, v])).collect();
    Value::Array(pairs)
}
