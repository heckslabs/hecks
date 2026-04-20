//! Behaviors IR — the intermediate representation for `_behavioral_tests.bluebook`
//!
//! Sibling to `ir::Domain` — emitted by `behaviors_parser::parse` from
//! sources whose top-level keyword is `Hecks.behaviors`. The runner
//! consumes this to execute in-memory tests against a source domain.

use std::collections::BTreeMap;

#[derive(Debug)]
pub struct TestSuite {
    /// The source domain name this suite tests (e.g., "Pizzas").
    pub name: String,
    pub vision: Option<String>,
    pub tests: Vec<Test>,
}

#[derive(Debug)]
pub struct Test {
    /// Human-readable sentence describing what's being tested.
    pub description: String,
    /// The command (or query) under test.
    pub tests_command: String,
    /// The aggregate the command/query lives on.
    pub on_aggregate: String,
    /// "command" or "query" — defaults to "command".
    pub kind: String,
    /// Zero or more arrange-phase command calls, in order.
    pub setups: Vec<TestSetup>,
    /// Act-phase arguments. BTreeMap for stable ordering across both parsers.
    pub input: BTreeMap<String, String>,
    /// Assert-phase key/value pairs. Reserved keys: count, refused, <attr>_size.
    pub expect: BTreeMap<String, String>,
}

#[derive(Debug)]
pub struct TestSetup {
    pub command: String,
    pub args: BTreeMap<String, String>,
}
