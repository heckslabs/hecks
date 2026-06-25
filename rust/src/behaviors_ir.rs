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
    /// Sibling bluebooks the runner should merge into the test domain.
    ///
    /// Populated by `loads "pulse", "body"` in the `.behaviors` DSL. Each
    /// entry is a bluebook name the runner resolves to a source file; the
    /// resolved bluebook's aggregates/policies/value_objects merge into the
    /// single Domain the tests execute against. Empty by default — every
    /// pre-i43 `.behaviors` file parses with an empty Vec and behaves
    /// identically to before.
    ///
    /// IR slot only in this commit: no consumer reads this field yet.
    pub loads: Vec<String>,
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
    /// Set-membership assertion over events fired during the act phase.
    ///
    /// Populated by `then_events_include "BodyPulse", "FatigueAccumulated"`
    /// in a test block. Complements strict-order `expect emits:` with a
    /// superset check suited to cross-bluebook cascades whose event ordering
    /// is a runtime-drain-order detail, not a semantic contract. Empty by
    /// default — pre-i43 tests behave identically.
    ///
    /// IR slot only in this commit: no consumer reads this field yet.
    pub events_include: Vec<String>,
}

#[derive(Debug)]
pub struct TestSetup {
    pub command: String,
    pub args: BTreeMap<String, String>,
}
