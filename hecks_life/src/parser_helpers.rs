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

/// Extract a state token from `text`: either a quoted "string" or a bare
/// token like `true`, `false`, or `:symbol`. Used by lifecycle parsing
/// where Ruby happily stringifies `true`/`false`/symbols into the IR.
pub fn extract_state_token(text: &str) -> Option<String> {
    let t = text.trim_start();
    if t.starts_with('"') {
        return extract_string(t);
    }
    // Bare token — strip a leading `:` (symbol form) and read alphanumerics.
    let body = t.strip_prefix(':').unwrap_or(t);
    let end = body
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(body.len());
    let tok = body[..end].trim().to_string();
    if tok.is_empty() { None } else { Some(tok) }
}

/// Check if line ends with ` do` (with optional block-arg list `|arg, ...|`).
/// Matches `... do`, `do`, and `... do |x|`, `... do |x, y|`.
pub fn ends_with_do_block(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.ends_with(" do") || trimmed == "do" {
        return true;
    }
    // `... do |args|` — strip a trailing |...| if present
    if trimmed.ends_with('|') {
        if let Some(open) = trimmed[..trimmed.len() - 1].rfind('|') {
            let head = trimmed[..open].trim_end();
            return head.ends_with(" do") || head == "do";
        }
    }
    false
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

// --- Shorthand syntax support ---

const SHORTHAND_TYPES: &[&str] = &[
    "String", "Integer", "Float", "Boolean", "JSON", "Date", "DateTime",
];

const KEYWORDS: &[&str] = &[
    "aggregate", "policy", "lifecycle", "value_object", "vow",
    "fixture", "category", "vision", "description", "Hecks",
    "String", "Integer", "Float", "Boolean", "JSON", "Date", "DateTime",
];

/// Detect shorthand attribute or reference lines.
pub fn is_shorthand_line(line: &str) -> bool {
    SHORTHAND_TYPES.iter().any(|t| {
        line.starts_with(t) && line[t.len()..].starts_with(|c: char| c == ' ' || c == '\t')
    }) || line.starts_with("list_of(")
       || line.starts_with("reference_to(")
}

/// Detect bare PascalCase command: `CreatePizza do` or `CreatePizza {`.
pub fn is_shorthand_command(line: &str) -> bool {
    let first_word = line.split_whitespace().next().unwrap_or("");
    if first_word.len() < 2 { return false; }
    let chars: Vec<char> = first_word.chars().collect();
    let is_pascal = chars[0].is_uppercase() && chars[1..].iter().any(|c| c.is_lowercase());
    is_pascal
        && (line.ends_with(" do") || line.contains('{'))
        && !KEYWORDS.iter().any(|k| first_word == *k)
}

/// Parse `String :name`, `Integer :count`, `list_of(Order) :tags`.
pub fn parse_shorthand_attribute(line: &str) -> Option<crate::ir::Attribute> {
    let list = line.starts_with("list_of(");
    let attr_type = if list {
        let open = line.find('(')? + 1;
        let close = line.find(')')?;
        line[open..close].trim().to_string()
    } else {
        let end = line.find(|c: char| c == ' ' || c == '\t')?;
        line[..end].to_string()
    };
    let name = extract_symbol(line)?;
    Some(crate::ir::Attribute { name, attr_type, default: None, list })
}

/// Parse `reference_to(Order)`, `reference_to(Order).as(:recent_purchase)`,
/// or `reference_to(Order, role: :recent_purchase)`. The Ruby DSL uses the
/// `role:` kwarg form; the Rust shorthand uses `.as()`. Both should yield
/// the same Reference IR.
pub fn parse_shorthand_reference(line: &str) -> Option<crate::ir::Reference> {
    let open = line.find('(')? + 1;
    let close = line.find(')')?;
    let inside = &line[open..close];
    // Target is the first identifier inside the parens (before any comma).
    let target = inside.split(',').next()?.trim().to_string();

    // Role can be set via:
    //   .as(:name) — Rust shorthand suffix
    //   role: :name — Ruby kwarg inside the parens
    // Falls back to snake-cased target.
    let name = if line.contains(".as(") {
        let as_pos = line.find(".as(")?;
        extract_symbol(&line[as_pos..]).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(role_pos) = inside.find("role:") {
        // Skip past the `role:` kwarg colon, then extract the :symbol
        let after_kwarg = &inside[role_pos + "role:".len()..];
        extract_symbol(after_kwarg).unwrap_or_else(|| to_snake_case(&target))
    } else {
        to_snake_case(&target)
    };

    let domain = if target.contains("::") {
        Some(target.split("::").next()?.to_string())
    } else {
        None
    };

    Some(crate::ir::Reference { name, target, domain })
}

/// Unified shorthand dispatcher — keeps call sites to a 3-line match.
pub enum ShorthandResult {
    Attribute(crate::ir::Attribute),
    Reference(crate::ir::Reference),
    None,
}

pub fn parse_shorthand(line: &str) -> ShorthandResult {
    if !is_shorthand_line(line) { return ShorthandResult::None; }
    if line.starts_with("reference_to(") {
        parse_shorthand_reference(line)
            .map(ShorthandResult::Reference)
            .unwrap_or(ShorthandResult::None)
    } else {
        parse_shorthand_attribute(line)
            .map(ShorthandResult::Attribute)
            .unwrap_or(ShorthandResult::None)
    }
}
