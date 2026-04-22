//! Vector math for behavioral test suites
//!
//! Extracts a 7-dimensional structural vector from a TestSuite and
//! computes Euclidean→similarity scoring for nearest-archetype matching.
//!
//! Vector dimensions:
//!   [test_count, avg_setups, command_tests, query_tests,
//!    lifecycle_tests, refused_tests, distinct_aggregates_tested]
//!
//! `seed_from_domain` derives the *expected* shape vector for tests
//! of a given source domain — so a domain with 6 commands and 2
//! queries seeds toward 8 tests, with avg_setups proportional to the
//! number of state-mutating commands the queries depend on.

use crate::behaviors_ir::TestSuite;
use crate::ir::Domain;
use std::collections::BTreeSet;

/// Extract a 7-D structural vector from a parsed test suite.
pub fn extract_vector(suite: &TestSuite) -> Vec<f64> {
    let test_count = suite.tests.len() as f64;
    let total_setups: usize = suite.tests.iter().map(|t| t.setups.len()).sum();
    let avg_setups = if test_count > 0.0 { total_setups as f64 / test_count } else { 0.0 };
    let command_tests = suite.tests.iter().filter(|t| t.kind == "command").count() as f64;
    let query_tests = suite.tests.iter().filter(|t| t.kind == "query").count() as f64;

    // Lifecycle tests: any test whose expect contains a `status` (or any
    // key matching a known lifecycle field) is plausibly a transition test.
    // Heuristic — works without cross-referencing the source domain.
    let lifecycle_tests = suite.tests.iter()
        .filter(|t| t.expect.contains_key("status"))
        .count() as f64;
    let refused_tests = suite.tests.iter()
        .filter(|t| t.expect.contains_key("refused"))
        .count() as f64;

    let distinct_aggs: BTreeSet<&str> = suite.tests.iter()
        .map(|t| t.on_aggregate.as_str())
        .collect();
    let distinct_aggregates = distinct_aggs.len() as f64;

    vec![
        test_count,
        avg_setups,
        command_tests,
        query_tests,
        lifecycle_tests,
        refused_tests,
        distinct_aggregates,
    ]
}

/// Derive an *expected* 7-D vector for tests of a source domain.
/// Seed reflects what a complete-coverage suite would look like:
/// one test per command, one per query, plus lifecycle and refused
/// variants where the source has them.
pub fn seed_from_domain(domain: &Domain) -> Vec<f64> {
    let cmd_tests: usize = domain.aggregates.iter().map(|a| a.commands.len()).sum();
    let query_tests: usize = domain.aggregates.iter().map(|a| a.queries.len()).sum();
    let givens_tests: usize = domain.aggregates.iter()
        .flat_map(|a| a.commands.iter())
        .map(|c| c.givens.len())
        .sum();
    let lifecycle_tests: usize = domain.aggregates.iter()
        .filter_map(|a| a.lifecycle.as_ref())
        .map(|l| l.transitions.len())
        .sum();

    let total = cmd_tests + query_tests + givens_tests + lifecycle_tests;
    let distinct_aggs = domain.aggregates.len();

    // Avg setups guess: queries always have ≥1 setup; lifecycle tests
    // need 1 setup to reach the from_state. Use a rough mean.
    let total_setups = query_tests.saturating_mul(2) + lifecycle_tests;
    let avg_setups = if total > 0 { total_setups as f64 / total as f64 } else { 0.0 };

    vec![
        total as f64,
        avg_setups,
        cmd_tests as f64,
        query_tests as f64,
        lifecycle_tests as f64,
        givens_tests as f64,
        distinct_aggs as f64,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::behaviors_ir::{Test, TestSetup};
    use std::collections::BTreeMap;

    fn mk_test(kind: &str, agg: &str, setups: usize, expect_key: Option<&str>) -> Test {
        let mut expect = BTreeMap::new();
        if let Some(k) = expect_key { expect.insert(k.to_string(), "x".to_string()); }
        Test {
            description: "t".into(),
            tests_command: "C".into(),
            on_aggregate: agg.into(),
            kind: kind.into(),
            setups: (0..setups).map(|_| TestSetup {
                command: "S".into(), args: BTreeMap::new(),
            }).collect(),
            input: BTreeMap::new(),
            expect,
            events_include: vec![],
        }
    }

    #[test]
    fn vector_counts_each_dimension() {
        let suite = TestSuite {
            name: "S".into(),
            vision: None,
            tests: vec![
                mk_test("command", "Pizza", 0, Some("name")),
                mk_test("command", "Pizza", 1, Some("toppings_size")),
                mk_test("query",   "Pizza", 3, Some("count")),
                mk_test("command", "Order", 1, Some("status")),
                mk_test("command", "Order", 0, Some("refused")),
            ],
            loads: vec![],
        };
        let v = extract_vector(&suite);
        assert_eq!(v[0], 5.0);                       // test_count
        assert!((v[1] - 1.0).abs() < 1e-9);          // avg_setups (5/5)
        assert_eq!(v[2], 4.0);                       // command_tests
        assert_eq!(v[3], 1.0);                       // query_tests
        assert_eq!(v[4], 1.0);                       // lifecycle (status key)
        assert_eq!(v[5], 1.0);                       // refused
        assert_eq!(v[6], 2.0);                       // distinct aggregates
    }
}
