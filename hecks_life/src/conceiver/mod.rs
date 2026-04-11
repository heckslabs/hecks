//! Conceiver — corpus-driven domain generation and evolution
//!
//! Scans existing .bluebook files to extract structural vectors,
//! finds nearest archetypes by cosine similarity, and generates
//! new domains or evolves existing ones.
//!
//! Usage:
//!   hecks-life conceive "Geology" "science of earth materials"
//!   hecks-life evolve target.bluebook --add "audit logging"

pub mod vector;
pub mod generator;
pub mod evolve;
pub mod commands;

use crate::ir::Domain;
use crate::parser;
use std::path::{Path, PathBuf};

/// A corpus entry: domain name, structural vector, source path.
pub struct CorpusEntry {
    pub name: String,
    pub vector: Vec<f64>,
    pub path: PathBuf,
    pub domain: Domain,
}

/// A match result from nearest-neighbor search.
pub struct Match {
    pub name: String,
    pub similarity: f64,
    pub path: PathBuf,
    pub domain: Domain,
}

/// Scan directories for .bluebook files, parse each, extract vectors.
pub fn scan_corpus(dirs: &[PathBuf]) -> Vec<CorpusEntry> {
    let mut entries = Vec::new();
    for dir in dirs {
        scan_dir(dir, &mut entries);
    }
    entries
}

fn scan_dir(dir: &Path, entries: &mut Vec<CorpusEntry>) {
    let read = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    for entry in read.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_dir(&path, entries);
        } else if path.extension().map(|e| e == "bluebook").unwrap_or(false) {
            if let Ok(source) = std::fs::read_to_string(&path) {
                let domain = parser::parse(&source);
                if domain.aggregates.is_empty() {
                    continue;
                }
                let vec = vector::extract_vector(&domain);
                entries.push(CorpusEntry {
                    name: domain.name.clone(),
                    vector: vec,
                    path: path.clone(),
                    domain,
                });
            }
        }
    }
}

/// Find the k nearest corpus entries to a seed vector.
pub fn find_nearest(seed: &[f64], corpus: Vec<CorpusEntry>, k: usize) -> Vec<Match> {
    let mut scored: Vec<(f64, CorpusEntry)> = corpus
        .into_iter()
        .map(|e| {
            let sim = vector::cosine_similarity(seed, &e.vector);
            (sim, e)
        })
        .collect();

    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored.truncate(k);

    scored
        .into_iter()
        .map(|(sim, e)| Match {
            name: e.name,
            similarity: sim,
            path: e.path,
            domain: e.domain,
        })
        .collect()
}
