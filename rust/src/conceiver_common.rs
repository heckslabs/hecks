//! Shared infrastructure for every conceiver
//!
//! The bluebook conceiver and the behaviors conceiver must not drift.
//! This module is one half of how that's enforced (the other half is
//! `tests/conceiver_parity.rs`).
//!
//! Two enforcement mechanisms together:
//!
//! 1. **Shared code, not parallel code.** Corpus scanning,
//!    nearest-neighbor search, and similarity math live HERE — both
//!    conceivers call the same functions. Drift in those primitives
//!    is impossible because there's only one implementation.
//!
//! 2. **Shared trait.** Every conceiver implements `Conceiver`, which
//!    fixes the per-conceiver contract: parse source, seed a vector,
//!    generate output text. Adding a new conceiver requires
//!    implementing every trait method — anything missing is a
//!    compile error.
//!
//! What can still drift: the *shape* of each conceiver's vector
//! (Domain has 9 dims, TestSuite has 7) and the format of generated
//! text. Those are intentionally per-conceiver. The parity test
//! checks the rest.

use std::path::{Path, PathBuf};

/// One entry in a parsed corpus: name, structural vector, source path,
/// the parsed item itself.
pub struct Entry<I> {
    pub name: String,
    pub vector: Vec<f64>,
    pub path: PathBuf,
    pub item: I,
}

/// A nearest-archetype match returned by `find_nearest`.
pub struct Match<I> {
    pub name: String,
    pub similarity: f64,
    pub path: PathBuf,
    pub item: I,
}

/// The contract every conceiver implements. Per-conceiver pieces
/// live here; everything else is shared. A `_marker` zero-sized
/// struct (`BluebookConceiver`, `BehaviorsConceiver`) implements
/// this trait — the trait isn't object-safe, it's only a contract.
pub trait Conceiver {
    /// What gets parsed out of a corpus file (e.g. `Domain`, `TestSuite`).
    type Item;

    /// What seeds a search. Vision string for bluebook conceiver,
    /// source `Domain` for behaviors conceiver.
    type Seed;

    /// Parse a source string into (name, item, vector). Return None if
    /// the source doesn't match this conceiver (wrong top-level keyword,
    /// empty/invalid, etc.). The returned vector must have the same
    /// length every time for a given conceiver — that length is the
    /// conceiver's vector dimensionality.
    fn parse_source(source: &str) -> Option<(String, Self::Item, Vec<f64>)>;

    /// Derive a seed vector from input. Must return a vector of the
    /// same length as `parse_source` returns.
    fn seed_vector(input: &Self::Seed) -> Vec<f64>;

    /// Generate output text given an input and a best-matched archetype.
    fn generate(input: &Self::Seed, archetype: &Self::Item) -> String;
}

/// Walk `dirs`, find every `.bluebook` file, parse via the conceiver,
/// and collect matching entries. Files that the conceiver's parser
/// returns None for are silently skipped (lets two conceivers share a
/// directory without stepping on each other).
pub fn scan_corpus<C: Conceiver>(dirs: &[PathBuf]) -> Vec<Entry<C::Item>> {
    let mut entries = Vec::new();
    for dir in dirs { scan_dir::<C>(dir, &mut entries); }
    entries
}

fn scan_dir<C: Conceiver>(dir: &Path, entries: &mut Vec<Entry<C::Item>>) {
    let read = match std::fs::read_dir(dir) { Ok(r) => r, Err(_) => return };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_dir::<C>(&path, entries);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                if let Some((name, item, vector)) = C::parse_source(&source) {
                    entries.push(Entry { name, vector, path: path.clone(), item });
                }
            }
        }
    }
}

/// k-nearest neighbors by Euclidean distance, mapped to similarity
/// `1.0 / (1.0 + dist)` so 1.0 = identical and 0.0 = far apart.
/// Same scoring function for every conceiver — there is exactly one.
pub fn find_nearest<I>(seed: &[f64], corpus: Vec<Entry<I>>, k: usize) -> Vec<Match<I>> {
    let mut scored: Vec<(f64, Entry<I>)> = corpus.into_iter()
        .map(|e| {
            let dist: f64 = seed.iter().zip(e.vector.iter())
                .map(|(a, b)| (a - b) * (a - b))
                .sum::<f64>()
                .sqrt();
            let sim = 1.0 / (1.0 + dist);
            (sim, e)
        })
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(k);
    scored.into_iter().map(|(sim, e)| Match {
        name: e.name, similarity: sim, path: e.path, item: e.item,
    }).collect()
}

/// Weighted cosine similarity. Weights have the same length as the
/// vectors. Both conceivers share this implementation — drift in
/// similarity math has caused subtle bugs in other systems and we're
/// pre-empting that.
pub fn cosine_similarity_weighted(a: &[f64], b: &[f64], weights: &[f64]) -> f64 {
    let wa: Vec<f64> = a.iter().zip(weights.iter()).map(|(x, w)| x * w).collect();
    let wb: Vec<f64> = b.iter().zip(weights.iter()).map(|(x, w)| x * w).collect();
    let dot: f64 = wa.iter().zip(wb.iter()).map(|(x, y)| x * y).sum();
    let mag_a: f64 = wa.iter().map(|x| x * x).sum::<f64>().sqrt();
    let mag_b: f64 = wb.iter().map(|x| x * x).sum::<f64>().sqrt();
    if mag_a == 0.0 || mag_b == 0.0 { return 0.0; }
    dot / (mag_a * mag_b)
}
