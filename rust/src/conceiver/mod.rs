//! Conceiver — corpus-driven domain generation and development
//!
//! Scans existing .bluebook files to extract structural vectors,
//! finds nearest archetypes, generates new domains.
//!
//! Mirrors `behaviors_conceiver/`. Both implement the `Conceiver`
//! trait from `conceiver_common`, share corpus/nearest/similarity
//! primitives, and have the same module layout (vector, generator,
//! commands). Drift between them is enforced against by
//! `tests/conceiver_parity.rs`.
//!
//! Usage:
//!   hecks-life conceive "Geology" "science of earth materials"
//!   hecks-life develop target.bluebook --add "audit logging"

pub mod vector;
pub mod generator;
pub mod develop;
pub mod commands;

use crate::conceiver_common::{self, Conceiver, Entry, Match};
use crate::ir::Domain;
use crate::parser;
use std::path::PathBuf;

/// Marker type for the bluebook conceiver. Carries no data — it just
/// gives the trait a `Self` to dispatch on.
pub struct BluebookConceiver;

impl Conceiver for BluebookConceiver {
    type Item = Domain;
    type Seed = String;

    fn parse_source(source: &str) -> Option<(String, Self::Item, Vec<f64>)> {
        // Skip behaviors files — different conceiver owns those.
        if crate::behaviors_parser::is_behaviors_source(source) { return None; }
        let domain = parser::parse(source);
        if domain.aggregates.is_empty() { return None; }
        let v = vector::extract_vector(&domain);
        let name = domain.name.clone();
        Some((name, domain, v))
    }

    fn seed_vector(input: &Self::Seed) -> Vec<f64> {
        vector::seed_from_description(input)
    }

    fn generate(input: &Self::Seed, archetype: &Self::Item) -> String {
        // input here is the vision string; the generator also needs a
        // name, which `commands.rs` handles. This trait method exists
        // for parity with BehaviorsConceiver — direct callers in
        // commands.rs use generator::generate_bluebook with both name
        // and vision explicitly.
        generator::generate_bluebook("Generated", input, archetype)
    }
}

// Public aliases — keeps existing call sites working through the
// refactor. Same names, same behavior, but routed through the
// shared `Conceiver` machinery so drift can't sneak in.
pub type CorpusEntry = Entry<Domain>;

/// Scan dirs for bluebook files, parse each, extract vectors.
/// Thin wrapper over `conceiver_common::scan_corpus` — kept so the
/// existing `commands.rs` call sites compile unchanged.
pub fn scan_corpus(dirs: &[PathBuf]) -> Vec<CorpusEntry> {
    conceiver_common::scan_corpus::<BluebookConceiver>(dirs)
}

/// Find k nearest. Behavior preserved: optional category filter
/// partitions the corpus first, falls back to full corpus if no
/// category matches.
pub fn find_nearest(seed: &[f64], corpus: Vec<CorpusEntry>, k: usize) -> Vec<Match<Domain>> {
    find_nearest_with_category(seed, corpus, k, None)
}

pub fn find_nearest_with_category(
    seed: &[f64],
    corpus: Vec<CorpusEntry>,
    k: usize,
    category: Option<&str>,
) -> Vec<Match<Domain>> {
    let (filtered, fallback) = if let Some(cat) = category {
        let (matched, rest): (Vec<_>, Vec<_>) = corpus
            .into_iter()
            .partition(|e| e.item.category.as_deref() == Some(cat));
        if matched.is_empty() { (rest, true) } else { (matched, false) }
    } else {
        (corpus, false)
    };
    if fallback {
        eprintln!("No domains with category {:?}, falling back to full corpus", category.unwrap_or(""));
    }
    conceiver_common::find_nearest(seed, filtered, k)
}
