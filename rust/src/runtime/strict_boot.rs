//! Interim host-language strictness. The parser is permissive by
//! design and will half-read what the reference implementation
//! refuses — a live hazard in the enforcement path, because a
//! half-read that only drops behavior projects to the SAME storage
//! shape and boots cleanly under an invalid domain definition. Until
//! the specializer derives both parsers from one definition, refuse
//! at least the detectable class: a word at aggregate-body level the
//! parser does not recognize but is close enough to be a near-miss of
//! one it does.
//!
//! A standalone text scan, deliberately: the IR structs are generated
//! from the language definition now, so parse-time bookkeeping has
//! nowhere to live on the Aggregate itself.
//!
//! `AGGREGATE_KEYWORDS` used to be a twelve-word, BLOCK-OPENING-ONLY
//! list hand-written here, "because nothing declares what the keywords
//! are" — its own comment, before `language/bluebook/syntax.bluebook`
//! existed. It had drifted: five of its twelve words (`view`, `rule`,
//! `factory`, `create`, and `invariant` — a real word, but typed in a
//! value object rather than an aggregate) were not words the language
//! admits at aggregate-body level at all, so each was treated as a
//! KNOWN keyword and let straight through the check meant to catch
//! exactly that. It is `bluebook::ir_syntax::AGGREGATE_KEYWORDS` now —
//! every word the language admits directly in an aggregate's own body,
//! projected from the language and held equal to it (in both
//! directions) by spec/syntax_conformance_spec.rb.
//!
//! THE FIRST PROJECTION ONLY COVERED WORDS THAT OPEN A `do` BLOCK,
//! because the scan's own line-matching only ever looked at lines
//! ending in `do`. `attribute`, `description`, and the bare-symbol form
//! of `identified_by` never open one, so a typo of one of THEM
//! (`atribute :cost, Money`) fell through the same hole the
//! block-keyword list was built to close — silently, exactly like any
//! other alien construct. The scan now checks every non-blank,
//! non-comment line at depth zero, not only the ones that open a block.

use crate::bluebook::ir_syntax::AGGREGATE_KEYWORDS;

pub struct NearMiss {
    pub aggregate: String,
    pub keyword: String,
    pub suggestion: String,
}

/// First near-miss keyword at aggregate-body level, if any.
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
        if depth == 0 && !line.is_empty() && !line.starts_with('#') {
            let word = line.split_whitespace().next().unwrap_or("");
            if let Some(suggestion) = suggest_keyword(word) {
                return Some(NearMiss {
                    aggregate: aggregate.clone().unwrap_or_default(),
                    keyword: word.to_string(),
                    suggestion,
                });
            }
        }
        if ends_with_do_block(line) {
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

fn suggest_keyword(word: &str) -> Option<String> {
    if word.is_empty() || AGGREGATE_KEYWORDS.contains(&word) {
        return None;
    }
    AGGREGATE_KEYWORDS
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
