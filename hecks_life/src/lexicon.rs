//! Lexicon — deterministic phrase matching for the vocabulary
//!
//! Two matching strategies, tried in order:
//!   1. Exact: hash map lookup of known phrases and translations
//!   2. Fuzzy: trigram similarity against all known phrases
//!
//! The lexicon is compiled from bluebooks — every command becomes a sentence,
//! every valid type bridge becomes a composition. No LLM needed.
//!
//! Usage:
//!   let lex = Lexicon::compile(bluebook_dir);
//!   let result = lex.match_input("make a pizza and toss it");

use crate::{parser, ir};
use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// A single executable sentence.
#[derive(Debug, Clone)]
pub struct Sentence {
    pub phrase: String,
    pub domain: String,
    pub aggregate: String,
    pub command: String,
    pub actor: Option<String>,
    pub parameters: Vec<String>,
    pub translations: Vec<String>,
}

/// Two commands chained by type compatibility.
#[derive(Debug, Clone)]
pub struct Composition {
    pub phrase: String,
    pub steps: Vec<CommandRef>,
    pub bridge_type: String,
    pub connector: String,
    pub translations: Vec<String>,
}

/// A reference to a specific command in a domain.
#[derive(Debug, Clone)]
pub struct CommandRef {
    pub domain: String,
    pub aggregate: String,
    pub command: String,
}

/// A match result from the lexicon.
#[derive(Debug)]
pub struct Match {
    pub path: Vec<CommandRef>,
    pub confidence: f64,
    pub matched_phrase: String,
    pub strategy: Strategy,
}

#[derive(Debug)]
pub enum Strategy {
    Exact,
    Fuzzy,
}

/// The compiled lexicon — all known phrases indexed for matching.
pub struct Lexicon {
    /// Exact lookup: normalized phrase -> command path
    exact: HashMap<String, Vec<CommandRef>>,
    /// All known phrases for fuzzy matching
    phrases: Vec<(String, Vec<CommandRef>)>,
    /// Stats
    pub sentence_count: usize,
    pub composition_count: usize,
}

impl Lexicon {
    /// Compile a lexicon from all bluebooks in a project directory.
    /// Walks nursery, catalog, aggregates, capabilities — everything.
    pub fn compile(project_dir: &str) -> Self {
        let dirs = vec!["nursery", "catalog", "aggregates", "capabilities"];
        Self::compile_dirs(project_dir, &dirs)
    }

    /// Compile from specific subdirectories within a project.
    pub fn compile_dirs(project_dir: &str, subdirs: &[&str]) -> Self {
        let mut sentences = Vec::new();
        let mut compositions = Vec::new();
        let project = Path::new(project_dir);

        // Parse all bluebooks from all directories
        let mut domains: Vec<(String, ir::Domain)> = Vec::new();
        for subdir in subdirs {
            let dir = project.join(subdir);
            if !dir.is_dir() { continue; }
            for entry in walk_bluebooks(&dir) {
                if let Ok(source) = fs::read_to_string(&entry) {
                    let domain = parser::parse(&source);
                    domains.push((entry.display().to_string(), domain));
                }
            }
        }

        // Extract sentences from every command in every domain
        for (_path, domain) in &domains {
            for agg in &domain.aggregates {
                for cmd in &agg.commands {
                    let phrase = command_to_phrase(&cmd.name, &agg.name);
                    let params: Vec<String> = cmd.attributes.iter()
                        .map(|a| a.name.clone())
                        .collect();
                    sentences.push(Sentence {
                        phrase,
                        domain: domain.name.clone(),
                        aggregate: agg.name.clone(),
                        command: cmd.name.clone(),
                        actor: cmd.role.clone(),
                        parameters: params,
                        translations: Vec::new(),
                    });
                }
            }
        }

        // Find valid compositions — commands whose output type matches another's input
        for (_pa, da) in &domains {
            for agg_a in &da.aggregates {
                for cmd_a in &agg_a.commands {
                    // This command produces an aggregate of type agg_a.name
                    let output_type = &agg_a.name;

                    for (_pb, db) in &domains {
                        for agg_b in &db.aggregates {
                            for cmd_b in &agg_b.commands {
                                // Does cmd_b accept output_type as input?
                                let accepts = cmd_b.references.iter()
                                    .any(|r| r.target == *output_type);
                                if !accepts { continue; }
                                // Skip self-references (update commands)
                                if da.name == db.name
                                    && agg_a.name == agg_b.name
                                    && cmd_a.name == cmd_b.name { continue; }

                                let phrase_a = command_to_phrase(&cmd_a.name, &agg_a.name);
                                let phrase_b = command_to_phrase(&cmd_b.name, &agg_b.name);
                                let phrase = format!("{} then {}", phrase_a, phrase_b);

                                compositions.push(Composition {
                                    phrase,
                                    steps: vec![
                                        CommandRef {
                                            domain: da.name.clone(),
                                            aggregate: agg_a.name.clone(),
                                            command: cmd_a.name.clone(),
                                        },
                                        CommandRef {
                                            domain: db.name.clone(),
                                            aggregate: agg_b.name.clone(),
                                            command: cmd_b.name.clone(),
                                        },
                                    ],
                                    bridge_type: output_type.clone(),
                                    connector: "then".into(),
                                    translations: Vec::new(),
                                });
                            }
                        }
                    }
                }
            }
        }

        // Build the index
        let mut exact: HashMap<String, Vec<CommandRef>> = HashMap::new();
        let mut phrases: Vec<(String, Vec<CommandRef>)> = Vec::new();

        for s in &sentences {
            let norm = normalize(&s.phrase);
            let refs = vec![CommandRef {
                domain: s.domain.clone(),
                aggregate: s.aggregate.clone(),
                command: s.command.clone(),
            }];
            exact.insert(norm.clone(), refs.clone());
            phrases.push((norm, refs));

            // Index translations too
            for t in &s.translations {
                let nt = normalize(t);
                exact.insert(nt.clone(), vec![CommandRef {
                    domain: s.domain.clone(),
                    aggregate: s.aggregate.clone(),
                    command: s.command.clone(),
                }]);
            }
        }

        for c in &compositions {
            let norm = normalize(&c.phrase);
            exact.insert(norm.clone(), c.steps.clone());
            phrases.push((norm, c.steps.clone()));

            for t in &c.translations {
                let nt = normalize(t);
                exact.insert(nt.clone(), c.steps.clone());
            }
        }

        let sc = sentences.len();
        let cc = compositions.len();

        Lexicon { exact, phrases, sentence_count: sc, composition_count: cc }
    }

    fn empty() -> Self {
        Lexicon {
            exact: HashMap::new(),
            phrases: Vec::new(),
            sentence_count: 0,
            composition_count: 0,
        }
    }

    /// Match input against the lexicon. Exact only.
    pub fn match_input(&self, input: &str) -> Option<Match> {
        let norm = normalize(input);

        if let Some(refs) = self.exact.get(&norm) {
            return Some(Match {
                path: refs.clone(),
                confidence: 1.0,
                matched_phrase: norm,
                strategy: Strategy::Exact,
            });
        }

        None
    }

    /// Trigram similarity matching — find the closest known phrase.
    fn fuzzy_match(&self, input: &str) -> Option<Match> {
        let input_trigrams = trigrams(input);
        if input_trigrams.is_empty() { return None; }

        let mut best_score: f64 = 0.0;
        let mut best: Option<&(String, Vec<CommandRef>)> = None;

        for entry in &self.phrases {
            let phrase_trigrams = trigrams(&entry.0);
            let score = trigram_similarity(&input_trigrams, &phrase_trigrams);
            if score > best_score {
                best_score = score;
                best = Some(entry);
            }
        }

        // Threshold: below 0.3 similarity, don't match
        if best_score < 0.3 { return None; }

        best.map(|(phrase, refs)| Match {
            path: refs.clone(),
            confidence: best_score,
            matched_phrase: phrase.clone(),
            strategy: Strategy::Fuzzy,
        })
    }

    /// Return all phrases that start with the given prefix.
    pub fn complete(&self, prefix: &str) -> Vec<&str> {
        let norm = normalize(prefix);
        if norm.is_empty() { return Vec::new(); }
        let mut results: Vec<&str> = self.phrases.iter()
            .map(|(phrase, _)| phrase.as_str())
            .filter(|p| p.starts_with(&norm))
            .take(10)
            .collect();
        results.sort();
        results.dedup();
        results
    }

    /// Print the full lexicon for debugging.
    pub fn dump(&self) {
        println!("Lexicon: {} sentences, {} compositions, {} total phrases",
            self.sentence_count, self.composition_count, self.phrases.len());
        println!();
        for (phrase, refs) in &self.phrases {
            let path: Vec<String> = refs.iter()
                .map(|r| format!("{}::{}::{}", r.domain, r.aggregate, r.command))
                .collect();
            println!("  {:50} → {}", phrase, path.join(" → "));
        }
    }
}

/// Convert "CreatePizza" to "create pizza", "PlaceOrder" to "place order".
fn command_to_phrase(command: &str, _aggregate: &str) -> String {
    let mut words = Vec::new();
    let mut current = String::new();

    for ch in command.chars() {
        if ch.is_uppercase() && !current.is_empty() {
            words.push(current.to_lowercase());
            current = String::new();
        }
        current.push(ch);
    }
    if !current.is_empty() {
        words.push(current.to_lowercase());
    }

    words.join(" ")
}

/// Normalize a phrase for matching: lowercase, strip punctuation, collapse whitespace.
fn normalize(input: &str) -> String {
    input.chars()
        .map(|c| if c.is_alphanumeric() || c == ' ' { c.to_ascii_lowercase() } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<&str>>()
        .join(" ")
}

/// Extract character trigrams from a string.
fn trigrams(s: &str) -> Vec<String> {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() < 3 { return vec![s.to_string()]; }
    chars.windows(3).map(|w| w.iter().collect()).collect()
}

/// Jaccard similarity between two trigram sets.
fn trigram_similarity(a: &[String], b: &[String]) -> f64 {
    if a.is_empty() || b.is_empty() { return 0.0; }

    let set_a: std::collections::HashSet<&str> = a.iter().map(|s| s.as_str()).collect();
    let set_b: std::collections::HashSet<&str> = b.iter().map(|s| s.as_str()).collect();

    let intersection = set_a.intersection(&set_b).count() as f64;
    let union = set_a.union(&set_b).count() as f64;

    if union == 0.0 { 0.0 } else { intersection / union }
}

/// Recursively find all .bluebook files in a directory tree.
fn walk_bluebooks(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut results = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            if path.is_dir() {
                results.extend(walk_bluebooks(&path));
            } else if path.extension().map_or(false, |ext| ext == "bluebook") {
                results.push(path);
            }
        }
    }
    results
}
