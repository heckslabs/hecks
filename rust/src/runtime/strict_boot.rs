//! Interim host-language strictness. The parser is permissive by
//! design and will half-read what the reference implementation
//! refuses — a live hazard in the enforcement path, because a
//! half-read that only drops behavior projects to the SAME storage
//! shape and boots cleanly under an invalid domain definition. Until
//! the specializer derives both parsers from one definition, refuse
//! at least the detectable class: a block keyword the parser skips
//! but recognizes as a near-miss.
//!
//! A standalone text scan, deliberately: the IR structs are generated
//! from the language definition now, so parse-time bookkeeping has
//! nowhere to live on the Aggregate itself.

pub struct NearMiss {
    pub aggregate: String,
    pub keyword: String,
    pub suggestion: String,
}

const BLOCK_KEYWORDS: &[&str] = &[
    "command",
    "query",
    "value_object",
    "entity",
    "invariant",
    "view",
    "rule",
    "policy",
    "factory",
    "lifecycle",
    "create",
    "identified_by",
];

/// First near-miss block keyword at aggregate-body level, if any.
pub fn scan(source: &str) -> Option<NearMiss> {
    let mut aggregate: Option<String> = None;
    let mut depth = 0usize;
    for raw in source.lines() {
        let line = raw.trim();
        if aggregate.is_none() {
            if line.starts_with("aggregate ") && ends_with_do_block(line) {
                aggregate = Some(extract_quoted(line).unwrap_or_default());
                depth = 0;
            }
            continue;
        }
        if line == "end" {
            if depth == 0 {
                aggregate = None;
            } else {
                depth -= 1;
            }
            continue;
        }
        if ends_with_do_block(line) {
            if depth == 0 {
                let word = line.split_whitespace().next().unwrap_or("");
                if let Some(suggestion) = suggest_block_keyword(word) {
                    return Some(NearMiss {
                        aggregate: aggregate.clone().unwrap_or_default(),
                        keyword: word.to_string(),
                        suggestion,
                    });
                }
            }
            depth += 1;
        }
    }
    None
}

fn ends_with_do_block(line: &str) -> bool {
    line == "do" || line.ends_with(" do") || (line.contains(" do |") && line.ends_with('|'))
}

fn extract_quoted(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

fn suggest_block_keyword(word: &str) -> Option<String> {
    if word.is_empty() || BLOCK_KEYWORDS.contains(&word) {
        return None;
    }
    BLOCK_KEYWORDS
        .iter()
        .map(|kw| (*kw, levenshtein(word, kw)))
        .filter(|(_, d)| *d <= 2)
        .min_by_key(|(_, d)| *d)
        .map(|(kw, _)| kw.to_string())
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = if ca == cb { 0 } else { 1 };
            cur[j + 1] = (prev[j + 1] + 1).min(cur[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}
