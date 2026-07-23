//! Parser helpers — string extraction and DSL pattern matching
//!
//! Utilities for pulling strings, symbols, blocks, and keywords
//! out of Bluebook DSL lines. Used by the parser module.
//!
//! [antibody-exempt: rust/src/parser_helpers.rs — kernel-floor
//!  parser primitives. The bluebook parser cannot itself be a
//!  bluebook (chicken-and-egg) ; this file is the Rust kernel
//!  that turns .bluebook source into IR. Mirror of
//!  ruby/lib/hecks/dsl in scope ; lockstep parser parity is
//!  enforced via parity/parity_test.rb and known_drift.txt.
//!  2026-05-09 — adds comment-aware ends_with_do_block (a `#`
//!  prefix on a trimmed line means "not a block-opener"), closing
//!  the synapse.bluebook drift entry where commented `query "cold"
//!  do` lines silently broke nested block depth-counting on the
//!  Rust side. Ruby's parser ignores `#` lines natively.]

/// Extract a `"..."` string literal from `line`, respecting backslash
/// escapes inside the quotes.
///
/// Two forms accepted, matching Ruby's parse semantics :
///
///   "simple"             → simple
///   "with \"quotes\""    → with "quotes"
///   "trailing \\"        → trailing \
///
/// Returns the UNESCAPED content (the way Ruby's `eval` of the string
/// literal would). Without the unescape step, Ruby's IR carries
/// `'with "quotes"'` while Rust would carry `'with \\"quotes\\"'` —
/// the escape-sequence parity drift that listed both
/// codegen/cli_dispatch_shape and codegen/parser_helpers_shape under
/// known_drift.txt. Both retire when this function unescapes correctly.
pub fn extract_string(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let mut out = String::new();
    let mut chars = line[start..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            // Recognised escape sequences mirror Ruby's basic set ;
            // anything else passes through with its leading backslash
            // dropped (so `\X` → `X`), matching Ruby's "ignore unknown
            // escape" behavior in double-quoted string literals.
            match chars.next() {
                Some('"')  => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('0')  => out.push('\0'),
                Some(other) => out.push(other),
                None => return None,
            }
            continue;
        }
        if c == '"' {
            return Some(out);
        }
        out.push(c);
    }
    None
}

/// Extract the quoted value of a `keyword: "..."` argument from a single line,
/// e.g. `version` from `Hecks.bluebook "X", version: "2026.06.27.1" do`. Finds the
/// `<keyword>:` marker and reads the first double-quoted string after it, reusing
/// `extract_string`'s escape handling. None when the keyword is absent. Line-
/// textual, matching how the Ruby DSL captures the keyword arg.
pub fn extract_kwarg_string(line: &str, keyword: &str) -> Option<String> {
    let marker = format!("{}:", keyword);
    let idx = line.find(&marker)?;
    extract_string(&line[idx + marker.len()..])
}

/// Extract a possibly multi-line `"..."` string literal beginning on
/// `lines[start]`, returning the UNESCAPED content and the number of
/// physical lines consumed.
///
/// Mirrors Ruby's string-literal lexing : when the opening `"` is not
/// closed on the same physical line, the literal continues onto the next
/// raw (untrimmed) line with a `\n` re-inserted at each break, preserving
/// continuation-line indentation byte-for-byte. Single-line literals close
/// on the first iteration and return `(value, 1)`, identical to
/// `extract_string`. Used for top-level `vision` strings, which may span
/// several physical lines (paragraphs, arrows, backticked phrases) — Ruby
/// reads them natively because the DSL is `instance_eval`'d ; the Rust
/// line-walker must reassemble them to stay byte-equal.
///
/// Divergence (unreachable in the corpus, guarded by the parity gate) : a
/// backslash at the very end of a physical line is a Ruby line-continuation
/// that drops both the `\` and the newline ; here it yields a `\n`.
pub fn extract_string_spanning(lines: &[&str], start: usize) -> (Option<String>, usize) {
    let first = lines[start];
    let open = match first.find('"') {
        Some(p) => p + 1,
        None => return (None, 1),
    };
    let mut out = String::new();
    let mut idx = start;
    let mut segment = &first[open..];
    loop {
        let mut chars = segment.chars();
        let mut closed = false;
        while let Some(c) = chars.next() {
            if c == '\\' {
                match chars.next() {
                    Some('"')  => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('n')  => out.push('\n'),
                    Some('t')  => out.push('\t'),
                    Some('r')  => out.push('\r'),
                    Some('0')  => out.push('\0'),
                    Some(other) => out.push(other),
                    None => break,
                }
                continue;
            }
            if c == '"' {
                closed = true;
                break;
            }
            out.push(c);
        }
        let consumed = idx - start + 1;
        if closed {
            return (Some(out), consumed);
        }
        idx += 1;
        if idx >= lines.len() {
            return (None, consumed);
        }
        out.push('\n');
        segment = lines[idx];
    }
}

/// Strip a trailing Ruby line-comment from `line`, returning the slice up
/// to (and trim-ending before) the first `#` that sits OUTSIDE a string
/// literal. Mirrors Ruby's lexer, which drops comments before the DSL
/// method is ever called — so `attribute :nickname, String  # "Trip"`
/// parses with type `String`, not `String  # "Trip"`. A `#` inside a
/// double-quoted string (e.g. `default: "#tag"`) is protected and left
/// intact. Lines with no out-of-string `#` are returned unchanged.
pub fn strip_trailing_comment(line: &str) -> &str {
    let mut in_str = false;
    let mut prev = '\0';
    for (idx, c) in line.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '#' if !in_str => return line[..idx].trim_end(),
            _ => {}
        }
        prev = c;
    }
    line
}

/// Two-string-form helper for `aggregate "Name", "Description" do` and
/// the matching `command`/`entity` shapes. Returns the UNESCAPED second
/// string — escape-aware throughout, mirroring `extract_string` above.
/// Embedded `\"` sequences in either string no longer prematurely
/// terminate parsing (the prior naïve `find('"')` scan truncated
/// descriptions containing escaped quotes — drift caught on
/// infrastructure.bluebook's adapter-family description).
pub fn extract_second_string(line: &str) -> Option<String> {
    // Skip past the first string with escape awareness.
    let first_open = line.find('"')? + 1;
    let mut idx = first_open;
    let bytes = line.as_bytes();
    while idx < bytes.len() {
        let b = bytes[idx];
        if b == b'\\' && idx + 1 < bytes.len() {
            idx += 2;
            continue;
        }
        if b == b'"' {
            idx += 1;
            break;
        }
        idx += 1;
    }
    // Locate opening quote of the second string.
    let second_open_offset = line[idx..].find('"')?;
    let second_open = idx + second_open_offset + 1;
    // Read second string, unescaping the recognised set (mirrors
    // extract_string's behaviour : unknown `\X` collapses to `X`).
    let mut out = String::new();
    let mut chars = line[second_open..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"')  => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('0')  => out.push('\0'),
                Some(other) => out.push(other),
                None => return None,
            }
            continue;
        }
        if c == '"' {
            return Some(out);
        }
        out.push(c);
    }
    None
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
    Some(rest.trim_end_matches([',', ' ']).to_string())
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
///
/// Commented lines (those whose trimmed form starts with `#`) are
/// never block-openers — even if they contain `do` syntactically.
/// Without this guard, a commented-out `# query "cold" do` would
/// increment the parser's depth counter and swallow subsequent
/// top-level declarations as if they were nested inside the
/// phantom block. Closes the synapse.bluebook drift entry whose
/// commented `do` lines silently broke `query "alive"` resolution
/// on the Rust side ; Ruby's parser ignores comments natively.
pub fn ends_with_do_block(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.starts_with('#') { return false; }
    if trimmed.ends_with(" do") || trimmed == "do" {
        return true;
    }
    // `... do |args|` — strip a trailing |...| if present
    if let Some(without_bar) = trimmed.strip_suffix('|') {
        if let Some(open) = without_bar.rfind('|') {
            let head = trimmed[..open].trim_end();
            return head.ends_with(" do") || head == "do";
        }
    }
    false
}

/// Extract a `kwarg: :symbol_name` pair from a DSL line. Returns the
/// symbol name (without the leading `:`) when found ; `None` when the
/// kwarg is absent or the value isn't a symbol.
///
/// Used by i250 to recognize `emits "X", identified_by: :stripe_event_id`
/// and pull `stripe_event_id` out cleanly. Generalises to other future
/// kwargs taking symbol values.
pub fn extract_kwarg_symbol(line: &str, kwarg: &str) -> Option<String> {
    let needle = format!("{kwarg}:");
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    let rest = rest.strip_prefix(':')?;
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() { None } else { Some(sym) }
}

/// Convert a string to snake_case.
///
/// Matches Ruby's ActiveSupport `#underscore` behavior for acronyms:
/// consecutive uppercase letters are treated as a single acronym, so
/// `DNAProfile` becomes `dna_profile` (not `d_n_a_profile`), and
/// `APIEndpoint` becomes `api_endpoint`. An underscore is inserted:
///   * before an uppercase letter preceded by a lowercase letter
///     (normal word boundary, e.g. `CamelCase` -> `camel_case`), or
///   * before an uppercase letter preceded by another uppercase letter
///     AND followed by a lowercase letter (acronym-ending boundary,
///     e.g. the `E` in `APIEndpoint`).
pub fn to_snake_case(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut result = String::with_capacity(s.len() + 4);
    for i in 0..chars.len() {
        let c = chars[i];
        if c.is_uppercase() && i > 0 {
            let prev = chars[i - 1];
            let next = chars.get(i + 1).copied();
            let prev_lower = prev.is_lowercase() || prev.is_ascii_digit();
            let acronym_end = prev.is_uppercase()
                && next.map(|n| n.is_lowercase()).unwrap_or(false);
            if prev_lower || acronym_end {
                result.push('_');
            }
        }
        result.push(c.to_lowercase().next().unwrap_or(c));
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
        line.starts_with(t) && line[t.len()..].starts_with([' ', '\t'])
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
        && !KEYWORDS.contains(&first_word)
}

/// Parse `String :name`, `Integer :count`, `list_of(Order) :tags`,
/// and the `default:` kwarg form `Integer :count, default: 0`.
pub fn parse_shorthand_attribute(line: &str) -> Option<crate::ir::Attribute> {
    let list = line.starts_with("list_of(");
    let attr_type = if list {
        let open = line.find('(')? + 1;
        let close = line.find(')')?;
        line[open..close].trim().to_string()
    } else {
        let end = line.find([' ', '\t'])?;
        line[..end].to_string()
    };
    let name = extract_symbol(line)?;
    let default = if line.contains("default:") {
        let pos = line.find("default:")?;
        let after = line[pos + "default:".len()..].trim();
        if let Some(rest) = after.strip_prefix('"') {
            // Quoted string default — strip quotes.
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        } else {
            // Bare token default (number, true, false, identifier).
            let token = after.split(|c: char| c == ',' || c.is_whitespace())
                .next().unwrap_or("").to_string();
            if token.is_empty() { None } else { Some(token) }
        }
    } else { None };
    let required = line.contains("required:")
        && line.split("required:").nth(1).map(|a| a.trim_start().starts_with("true")).unwrap_or(false);
    Some(crate::ir::Attribute { name, attr_type, default, list, required, enum_values: vec![], pattern: None, hint: None, logged: true })
}

/// Parse a reference declaration in any of these forms:
///
///   reference_to(Order)                            — name = `order` (snake target)
///   reference_to(Order, as: :recent_purchase)      — canonical alias kwarg
///   reference_to(Order, role: :recent_purchase)    — legacy kwarg, still accepted
///   reference_to(Order).as(:recent_purchase)       — Rust-style suffix
///   reference_to(Order) :recent_purchase           — trailing-symbol shorthand
///
/// All five resolve to the same Reference IR. Canonical going forward
/// is `as:`; the others remain accepted so existing bluebooks keep
/// parsing while authors migrate.
pub fn parse_shorthand_reference(line: &str) -> Option<crate::ir::Reference> {
    let open = line.find('(')? + 1;
    let close = line.find(')')?;
    let inside = &line[open..close];
    let after_close = &line[close + 1..];
    // Target is the first identifier inside the parens (before any comma).
    let target = inside.split(',').next()?.trim().to_string();

    let name = if line.contains(".as(") {
        // `.as(:foo)` Rust-style suffix.
        let as_pos = line.find(".as(")?;
        extract_symbol(&line[as_pos..]).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(pos) = inside.find(", as:") {
        // `, as: :foo` — canonical kwarg.
        let after = &inside[pos + ", as:".len()..];
        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(pos) = inside.find("as:") {
        // `as: :foo` — also accepted (no leading comma).
        let after = &inside[pos + "as:".len()..];
        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(role_pos) = inside.find("role:") {
        // `role: :foo` — legacy, kept for back-compat.
        let after_kwarg = &inside[role_pos + "role:".len()..];
        extract_symbol(after_kwarg).unwrap_or_else(|| to_snake_case(&target))
    } else if after_close.trim_start().starts_with(':') {
        // `reference_to(Order) :foo` — trailing-symbol shorthand
        // (mirrors `String :name` style on attributes).
        extract_symbol(after_close).unwrap_or_else(|| to_snake_case(&target))
    } else {
        to_snake_case(&target)
    };

    let domain = if target.contains("::") {
        Some(target.split("::").next()?.to_string())
    } else {
        None
    };

    // Reference gained `cardinality` and `kind` fields; the shorthand
    // parser routes through Reference::single (LegacyReferenceTo,
    // single cardinality) so the construction stays valid as the
    // struct grows.
    Some(crate::ir::Reference::single(name, target, domain))
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

#[cfg(test)]
mod snake_case_tests {
    use super::to_snake_case;

    #[test]
    fn simple_camel_case() {
        assert_eq!(to_snake_case("CamelCase"), "camel_case");
    }

    #[test]
    fn single_word_pascal() {
        assert_eq!(to_snake_case("Pizza"), "pizza");
    }

    #[test]
    fn all_lowercase_passthrough() {
        assert_eq!(to_snake_case("dreiletter"), "dreiletter");
    }

    #[test]
    fn pascal_with_no_internal_caps() {
        assert_eq!(to_snake_case("Dreiletter"), "dreiletter");
    }

    #[test]
    fn three_letter_leading_acronym() {
        assert_eq!(to_snake_case("DNAProfile"), "dna_profile");
    }

    #[test]
    fn uld_pallet() {
        assert_eq!(to_snake_case("ULDPallet"), "uld_pallet");
    }

    #[test]
    fn cbp_inspection() {
        assert_eq!(to_snake_case("CBPInspection"), "cbp_inspection");
    }

    #[test]
    fn ipm_plan() {
        assert_eq!(to_snake_case("IPMPlan"), "ipm_plan");
    }

    #[test]
    fn hvac_equipment() {
        assert_eq!(to_snake_case("HVACEquipment"), "hvac_equipment");
    }

    #[test]
    fn api_endpoint() {
        assert_eq!(to_snake_case("APIEndpoint"), "api_endpoint");
    }

    #[test]
    fn two_letter_leading_acronym() {
        assert_eq!(to_snake_case("AIAnalysis"), "ai_analysis");
    }

    #[test]
    fn trailing_acronym() {
        assert_eq!(to_snake_case("DigitalID"), "digital_id");
    }

    #[test]
    fn already_snake_case() {
        assert_eq!(to_snake_case("already_snake"), "already_snake");
    }

    #[test]
    fn empty_string() {
        assert_eq!(to_snake_case(""), "");
    }

    #[test]
    fn single_uppercase_letter() {
        assert_eq!(to_snake_case("A"), "a");
    }
}
