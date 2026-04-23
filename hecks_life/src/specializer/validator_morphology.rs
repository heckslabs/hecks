//! Morphology support for the `validator` Phase D port.
//!
//! Owns the block of const tables + `first_word` + `is_not_verb` that
//! sits between the `aggregates_have_commands` and `command_naming`
//! rules in the generated validator.rs. Split out from
//! `validator_checks.rs` so neither file crosses the 200-LoC cap:
//!
//!   validator_checks.rs      — the seven `check_kind` emitters
//!   validator_morphology.rs  — `emit_command_naming_support`, the
//!                              `format_suffix_list` / `format_verb_*`
//!                              helpers and their hand-formatted column
//!                              widths
//!
//! Byte-identity policy — column widths in `format_verb_exceptions`
//! and `format_verb_suffixes` are hardcoded to match the Ruby spec.
//! The hand-formatted output IS the contract; do not try to infer
//! widths dynamically.
//!
//! Usage:
//!   let block = emit_command_naming_support(&fixtures);
//!
//! [antibody-exempt: hecks_life/src/specializer/validator_morphology.rs —
//!  Phase D — Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;

/// Emit the const tables + `first_word` + `is_not_verb` support block
/// that sits between the `aggregates_have_commands` and `command_naming`
/// rules in the generated validator.rs.
pub fn emit_command_naming_support(fixtures: &[Fixture]) -> String {
    let suffixes = util::by_aggregate(fixtures, "SuffixTable");
    let nouns: Vec<&str> = suffixes
        .iter()
        .filter(|s| util::attr(s, "table") == "noun")
        .map(|s| util::attr(s, "suffix"))
        .collect();
    let adjs: Vec<&str> = suffixes
        .iter()
        .filter(|s| util::attr(s, "table") == "adj")
        .map(|s| util::attr(s, "suffix"))
        .collect();

    let exceptions = util::by_aggregate(fixtures, "ExceptionWord");
    let false_pos: Vec<&str> = exceptions
        .iter()
        .filter(|e| util::attr(e, "category") == "false_positive")
        .map(|e| util::attr(e, "word"))
        .collect();

    format!(
        "\
/// Command names must start with a verb — detected by morphological patterns.
/// Flipped logic: a command is imperative by definition. We only reject if
/// the first word is provably NOT a verb (noun/adjective suffixes).
/// Everything else passes — commands are verbs until proven otherwise.

/// Suffixes that prove a word is a noun — not a verb.
const NOUN_SUFFIXES: &[&str] = &[
{nouns_block}
];

/// Suffixes that prove a word is an adjective — not a verb.
const ADJ_SUFFIXES: &[&str] = &[
{adjs_block}
];

/// Words that look like they could be verbs but are actually nouns
/// when used as command first-words. Very short list — only add
/// proven false positives.
const FALSE_POSITIVES: &[&str] = &[
{false_pos_block}
];

/// Extract the first word from a PascalCase name.
fn first_word(name: &str) -> String {{
    let mut word = String::new();
    for (i, c) in name.chars().enumerate() {{
        if i > 0 && c.is_uppercase() {{ break; }}
        word.push(c);
    }}
    word
}}

/// A command first-word is NOT a verb if it matches noun/adjective patterns.
/// Everything else is assumed to be a verb — commands are imperative.
fn is_not_verb(word: &str) -> bool {{
    let lower = word.to_lowercase();

    // Too short to classify — single char is fine (commands like \"X\" are weird but not invalid)
    if lower.len() < 2 {{ return false; }}

    // Known false positives — articles, possessives, adjectives used as names
    if FALSE_POSITIVES.iter().any(|fp| *fp == word) {{ return true; }}

    // Words ending in noun suffixes that are actually verbs
    let verb_exceptions = {verb_exceptions};
    if verb_exceptions.iter().any(|v| lower == *v) {{ return false; }}

    // Verb suffixes — if these match, the word is a verb even if it
    // also matches a noun/adjective suffix (verb wins)
    let verb_suffixes = {verb_suffixes};
    let has_verb_suffix = verb_suffixes.iter().any(|s| lower.ends_with(s));

    // Noun suffixes — if it ends like a noun AND doesn't have a verb suffix, reject
    for suffix in NOUN_SUFFIXES {{
        if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {{
            return true;
        }}
    }}

    // Adjective suffixes — same logic
    for suffix in ADJ_SUFFIXES {{
        if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {{
            return true;
        }}
    }}

    // Everything else is a verb. Commands are imperative by definition.
    false
}}

",
        nouns_block = format_suffix_list(&nouns, 7),
        adjs_block = format_suffix_list(&adjs, 8),
        false_pos_block = format_suffix_list(&false_pos, 7),
        verb_exceptions = format_verb_exceptions(fixtures),
        verb_suffixes = format_verb_suffixes(fixtures),
    )
}

/// Chunk `items` into lines of at most `per_line` strings, each line
/// indented four spaces and terminated with a trailing comma. Matches
/// Ruby `items.each_slice(per_line).map { ... }.join("\n")`.
fn format_suffix_list(items: &[&str], per_line: usize) -> String {
    items
        .chunks(per_line)
        .map(|chunk| {
            let quoted: Vec<String> = chunk.iter().map(|s| format!("\"{}\"", s)).collect();
            format!("    {},", quoted.join(", "))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Hand-formatted verb-exception list with hardcoded column widths
/// matching the Ruby spec. 24 words split 3+1 / 6 / 5 / 5 / 4.
fn format_verb_exceptions(fixtures: &[Fixture]) -> String {
    let words: Vec<&str> = util::by_aggregate(fixtures, "ExceptionWord")
        .into_iter()
        .filter(|e| util::attr(e, "category") == "verb_exception")
        .map(|e| util::attr(e, "word"))
        .collect();
    let lines = vec![
        format!("[\"{}\", \"{}\",", words[0..3].join("\", \""), words[3]),
        format!("        \"{}\",", words[4..10].join("\", \"")),
        format!("        \"{}\",", words[10..15].join("\", \"")),
        format!("        \"{}\",", words[15..20].join("\", \"")),
        format!("        \"{}\"]", words[20..24].join("\", \"")),
    ];
    lines.join("\n")
}

/// Hand-formatted verb-suffix list: first 7 inline, remainder on a
/// continuation line indented 8 spaces. Matches the Ruby emitter.
fn format_verb_suffixes(fixtures: &[Fixture]) -> String {
    let suffixes: Vec<&str> = util::by_aggregate(fixtures, "SuffixTable")
        .into_iter()
        .filter(|s| util::attr(s, "table") == "verb")
        .map(|s| util::attr(s, "suffix"))
        .collect();
    let head: Vec<String> = suffixes[0..7]
        .iter()
        .map(|s| format!("\"{}\"", s))
        .collect();
    let tail: Vec<String> = suffixes[7..]
        .iter()
        .map(|s| format!("\"{}\"", s))
        .collect();
    format!("[{},\n        {}]", head.join(", "), tail.join(", "))
}
