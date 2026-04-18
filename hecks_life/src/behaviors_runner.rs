//! Behaviors test runner — executes a TestSuite against a source domain
//!
//! Pure-memory by design: uses `Runtime::boot(domain)` (no `data_dir`,
//! no hecksagon, no adapters). Each test gets a fresh runtime so
//! state doesn't leak across tests. If a test triggers IO, the source
//! bluebook is doing something it shouldn't — fix the bluebook, not
//! the test.
//!
//! Usage:
//!   hecks-life behaviors path/to/X_behavioral_tests.bluebook
//!
//! The runner finds the source bluebook by stripping the
//! `_behavioral_tests` suffix (e.g. `pizzas_behavioral_tests.bluebook`
//! → `pizzas.bluebook`).

use crate::behaviors_ir::{Test, TestSuite};
use crate::ir::Domain;
use crate::parser;
use crate::runtime::{Runtime, RuntimeError, Value};
use std::collections::{BTreeMap, HashMap};

#[derive(Debug, PartialEq)]
pub enum TestStatus { Pass, Fail, Error }

pub struct TestRun {
    pub description: String,
    pub status: TestStatus,
    pub message: Option<String>,
}

impl TestRun {
    fn pass(desc: &str) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Pass, message: None }
    }
    fn fail(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Fail, message: Some(msg.into()) }
    }
    fn error(desc: &str, msg: impl Into<String>) -> Self {
        TestRun { description: desc.into(), status: TestStatus::Error, message: Some(msg.into()) }
    }
}

pub struct SuiteResult {
    pub runs: Vec<TestRun>,
}

impl SuiteResult {
    pub fn passed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Pass).count() }
    pub fn failed(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Fail).count() }
    pub fn errored(&self) -> usize { self.runs.iter().filter(|r| r.status == TestStatus::Error).count() }
    pub fn all_passed(&self) -> bool { self.failed() == 0 && self.errored() == 0 }
}

/// Run every test in `suite` against `source` (re-parsed per test for
/// state isolation). Returns one TestRun per test, in source order.
pub fn run_suite(source_text: &str, suite: &TestSuite) -> SuiteResult {
    let runs = suite.tests.iter()
        .map(|t| run_one(source_text, t))
        .collect();
    SuiteResult { runs }
}

fn run_one(source_text: &str, test: &Test) -> TestRun {
    // Fresh in-memory runtime per test. Repositories start empty;
    // no data_dir means no heki persistence, no disk IO.
    let domain: Domain = parser::parse(source_text);
    let mut rt = Runtime::boot(domain);

    // Replay setup commands.
    for setup in &test.setups {
        let attrs = to_runtime_attrs(&setup.args);
        if let Err(e) = rt.dispatch(&setup.command, attrs) {
            return TestRun::error(
                &test.description,
                format!("setup `{}` failed: {}", setup.command, e),
            );
        }
    }

    // Dispatch the input. Queries are dispatched via resolve_query;
    // commands via the regular dispatch path.
    if test.kind == "query" {
        return run_query(&rt, test);
    }

    let input_attrs = to_runtime_attrs(&test.input);
    let result = rt.dispatch(&test.tests_command, input_attrs);

    // The expect map drives every assertion. `refused` is a special
    // key that asserts the dispatch failed with a matching given-clause
    // message; everything else asserts on final state.
    if let Some(expected_msg) = test.expect.get("refused") {
        return match result {
            Err(RuntimeError::GivenFailed { message, .. }) => {
                if message == *expected_msg {
                    TestRun::pass(&test.description)
                } else {
                    TestRun::fail(&test.description,
                        format!("expected refused: {:?}, got: {:?}", expected_msg, message))
                }
            }
            Err(other) => TestRun::fail(&test.description,
                format!("expected refused: {:?}, got error: {}", expected_msg, other)),
            Ok(_) => TestRun::fail(&test.description,
                format!("expected refused: {:?}, but command succeeded", expected_msg)),
        };
    }

    let result = match result {
        Ok(r) => r,
        Err(e) => return TestRun::error(&test.description, format!("dispatch failed: {}", e)),
    };

    // Final-state assertions against the aggregate that was acted on.
    let state = match rt.find(&test.on_aggregate, &result.aggregate_id) {
        Some(s) => s,
        None => return TestRun::fail(&test.description,
            format!("aggregate {}#{} not found after dispatch", test.on_aggregate, result.aggregate_id)),
    };

    for (key, expected) in &test.expect {
        if key == "refused" { continue; } // handled above
        if let Some(prefix) = key.strip_suffix("_size") {
            // List length assertion: `toppings_size: 1` → state.toppings.len() == 1
            let actual = match state.get(prefix) {
                Value::List(v) => v.len(),
                _ => 0,
            };
            let expected_n: usize = expected.parse().unwrap_or(0);
            if actual != expected_n {
                return TestRun::fail(&test.description,
                    format!("expected {}.size == {}, got {}", prefix, expected_n, actual));
            }
            continue;
        }
        // Plain attribute equality. Compare the field's display form to
        // the expected source-token string — both parsers stringify
        // the same way, so this is the canonical comparison.
        let actual = state.get(key).to_string();
        if actual != *expected {
            return TestRun::fail(&test.description,
                format!("expected {}: {:?}, got {:?}", key, expected, actual));
        }
    }

    TestRun::pass(&test.description)
}

fn run_query(rt: &Runtime, test: &Test) -> TestRun {
    // Build a String-keyed attrs map (resolve_query's signature).
    let attrs: HashMap<String, String> = test.input.iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let result = rt.resolve_query(&test.tests_command, &attrs);

    // The `count` expect key is the standard query assertion: count
    // matching records in the result. Other expect keys aren't yet
    // wired for queries — they'd need richer query result inspection.
    if let Some(expected) = test.expect.get("count") {
        let expected_n: usize = expected.parse().unwrap_or(0);
        let actual = count_query_records(&result);
        if actual != expected_n {
            return TestRun::fail(&test.description,
                format!("expected query count == {}, got {}", expected_n, actual));
        }
        return TestRun::pass(&test.description);
    }

    TestRun::pass(&test.description)
}

/// Convert behaviors-IR string args (the source-token form) into the
/// dynamic Value type the runtime dispatch loop expects. Numbers stay
/// numbers; quoted strings come through unwrapped (already).
fn to_runtime_attrs(args: &BTreeMap<String, String>) -> HashMap<String, Value> {
    args.iter()
        .map(|(k, v)| (k.clone(), parse_value(v)))
        .collect()
}

fn parse_value(s: &str) -> Value {
    if let Ok(n) = s.parse::<i64>() { return Value::Int(n); }
    if s == "true" { return Value::Bool(true); }
    if s == "false" { return Value::Bool(false); }
    Value::Str(s.to_string())
}

/// Count records in a resolve_query result. The result shape is
/// `{ "state": [..] }` for multi-record, `{ "state": {..} }` for one,
/// or `{ "state": [] }` for none.
fn count_query_records(result: &serde_json::Value) -> usize {
    match result.get("state") {
        Some(serde_json::Value::Array(a)) => a.len(),
        Some(serde_json::Value::Object(_)) => 1,
        _ => 0,
    }
}
