//! Behaviors conceiver — corpus-driven behavioral test generation
//!
//! Mirror of `conceiver/`. Both implement the `Conceiver` trait from
//! `conceiver_common`, share corpus/nearest/similarity primitives,
//! and have the same module layout (vector, generator, commands).
//! Drift between them is enforced against by `tests/conceiver_parity.rs`.
//!
//! Usage:
//!   hecks-life conceive-behaviors path/to/source.bluebook [--corpus dir1 dir2]

pub mod vector;
pub mod generator;
pub mod commands;

use crate::behaviors_ir::TestSuite;
use crate::behaviors_parser;
use crate::conceiver_common::{Conceiver, Match};
use crate::ir::Domain;

/// Marker type. Carries no data — gives the trait a `Self` to dispatch on.
pub struct BehaviorsConceiver;

impl Conceiver for BehaviorsConceiver {
    type Item = TestSuite;
    type Seed = Domain;

    fn parse_source(source: &str) -> Option<(String, Self::Item, Vec<f64>)> {
        if !behaviors_parser::is_behaviors_source(source) { return None; }
        let suite = behaviors_parser::parse(source);
        if suite.tests.is_empty() { return None; }
        let v = vector::extract_vector(&suite);
        let name = suite.name.clone();
        Some((name, suite, v))
    }

    fn seed_vector(input: &Self::Seed) -> Vec<f64> {
        vector::seed_from_domain(input)
    }

    fn generate(input: &Self::Seed, archetype: &Self::Item) -> String {
        generator::generate_behaviors(input, Some(archetype))
    }
}

// Convenience accessor on the shared Match type — keeps commands.rs
// readable when it only needs the suite (not name/sim/path).
pub trait MatchSuiteExt {
    fn suite_owned(self) -> TestSuite;
}
impl MatchSuiteExt for Match<TestSuite> {
    fn suite_owned(self) -> TestSuite { self.item }
}
