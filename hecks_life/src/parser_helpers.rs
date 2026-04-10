//! Parser helpers — string extraction and DSL pattern matching
//!
//! Utilities for pulling strings, symbols, blocks, and keywords
//! out of Bluebook DSL lines. Used by the parser module.

pub fn extract_string(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

pub fn extract_second_string(line: &str) -> Option<String> {
    let first_end = line.find('"')? + 1;
    let after_first = line[first_end..].find('"')? + first_end + 1;
    let start = line[after_first..].find('"')? + after_first + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
}

pub fn extract_symbol(line: &str) -> Option<String> {
    let start = line.find(':')? + 1;
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() { None } else { Some(sym) }
}

pub fn extract_word_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_' && c != ':')
        .unwrap_or(rest.len());
    let word = rest[..end].trim().to_string();
    if word.is_empty() { None } else { Some(word) }
}

pub fn extract_block(line: &str) -> Option<String> {
    let start = line.find('{')? + 1;
    let end = line.rfind('}')?;
    Some(line[start..end].trim().to_string())
}

pub fn extract_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    Some(rest.trim_end_matches(|c: char| c == ',' || c == ' ').to_string())
}

/// Check if line ends with ` do` as a whole word (not "domain", "document", etc.)
pub fn ends_with_do_block(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.ends_with(" do") || trimmed == "do"
}

pub fn to_snake_case(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            result.push('_');
        }
        result.push(c.to_lowercase().next().unwrap());
    }
    result
}
