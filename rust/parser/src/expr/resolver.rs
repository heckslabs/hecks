//! Parses value expressions into a `Resolver` tree (port of `resolver.rb#parse`).

use super::evaluator::Evaluator;
use super::{find_operator, top_level_index, Operator};

/// Which of `all?`, `any?` or `none?` a block predicate uses.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BlockMode {
    All,
    Any,
    None,
}

impl BlockMode {
    pub fn rust_name(&self) -> &'static str {
        match self {
            BlockMode::All => "All",
            BlockMode::Any => "Any",
            BlockMode::None => "None",
        }
    }

    /// The lowercase spelling written into the AST JSON.
    pub fn json_name(&self) -> &'static str {
        match self {
            BlockMode::All => "all",
            BlockMode::Any => "any",
            BlockMode::None => "none",
        }
    }
}

#[derive(Debug, Clone)]
pub enum Resolver {
    IntegerLiteral(i64),
    FloatLiteral(f64),
    /// Sliced verbatim between the quotes; no escape processing, as in Ruby.
    StringLiteral(String),
    BoolLiteral(bool),
    NilLiteral,
    Addition(Box<Resolver>, Box<Resolver>),
    SignTest { operator: Operator, receiver: Box<Resolver> },
    Empty(Box<Resolver>),
    ToS(Box<Resolver>),
    Modulo { receiver: Box<Resolver>, divisor: Box<Resolver> },
    Size(Box<Resolver>),
    Lookup(String),
    /// `["active", "suspended"]`: a literal set, the haystack of an `.include?`.
    ArrayLiteral(Vec<Resolver>),
    /// `receiver.any? { |param| predicate }` and siblings; the body is parsed as a predicate.
    BlockPredicate { mode: BlockMode, receiver: Box<Resolver>, param: String, predicate: Box<Evaluator> },
    /// `receiver.match?(/pattern/flags)`: the pattern text is kept verbatim.
    MatchesRegex { receiver: Box<Resolver>, pattern: String, flags: String },
    /// `receiver.present?` (`negated: false`) or `receiver.blank?` (`negated: true`).
    Presence { receiver: Box<Resolver>, negated: bool },
    /// `receiver.set?` (`negated: false`) or `receiver.unset?` (`negated: true`): only `!nil?`.
    Assignment { receiver: Box<Resolver>, negated: bool },
    /// `receiver.split("sep")`: the separator is sliced verbatim between the quotes.
    Split { receiver: Box<Resolver>, separator: String },
    /// `receiver.first`.
    First(Box<Resolver>),
    /// `receiver.last`.
    Last(Box<Resolver>),
    /// `receiver.start_with?("substring")`.
    StartsWith { receiver: Box<Resolver>, substring: String },
    /// `receiver.end_with?("substring")`.
    EndsWith { receiver: Box<Resolver>, substring: String },
    /// `receiver.find { |param| predicate }.a.b`.
    Find { receiver: Box<Resolver>, param: String, predicate: Box<Evaluator>, path: Vec<String> },
}

const SIGN_TESTS: [(&str, &str); 3] = [("positive?", ">"), ("negative?", "<"), ("zero?", "==")];

pub fn parse(expr: &str) -> Resolver {
    let expr = expr.trim();

    if let Some(inner) = strip_suffix_dotted(expr, "length") {
        return Resolver::Size(Box::new(parse(inner)));
    }

    if is_integer_literal(expr) {
        return Resolver::IntegerLiteral(expr.parse::<i64>().unwrap_or_else(|_| panic!("bad integer literal {expr:?}")));
    }
    if is_float_literal(expr) {
        return Resolver::FloatLiteral(expr.parse::<f64>().unwrap_or_else(|_| panic!("bad float literal {expr:?}")));
    }
    if let Some(s) = quoted(expr) {
        return Resolver::StringLiteral(s.to_string());
    }
    if expr == "true" {
        return Resolver::BoolLiteral(true);
    }
    if expr == "false" {
        return Resolver::BoolLiteral(false);
    }
    if expr == "nil" {
        return Resolver::NilLiteral;
    }
    if let Some(elements) = array_elements(expr) {
        return Resolver::ArrayLiteral(elements.iter().map(|element| parse(element)).collect());
    }

    if let Some((left, right)) = split_addition(expr) {
        return Resolver::Addition(Box::new(parse(left)), Box::new(parse(right)));
    }

    if let Some((receiver, test)) = match_suffix(expr, &SIGN_TESTS.map(|(s, _)| s)) {
        let symbol = SIGN_TESTS.iter().find(|(s, _)| *s == test).unwrap().1;
        return Resolver::SignTest { operator: find_operator(symbol), receiver: Box::new(parse(receiver)) };
    }

    if let Some(inner) = strip_suffix_dotted(expr, "empty?") {
        return Resolver::Empty(Box::new(parse(inner)));
    }
    if let Some(inner) = strip_suffix_dotted(expr, "to_s") {
        return Resolver::ToS(Box::new(parse(inner)));
    }

    if let Some((receiver, divisor)) = match_call(expr, ".modulo(") {
        return Resolver::Modulo { receiver: Box::new(parse(receiver)), divisor: Box::new(parse(divisor)) };
    }

    if let Some(inner) = strip_suffix_dotted(expr, "size") {
        return Resolver::Size(Box::new(parse(inner)));
    }

    if let Some((receiver, pattern, flags)) = match_regex(expr) {
        return Resolver::MatchesRegex { receiver: Box::new(parse(receiver)), pattern: pattern.to_string(), flags: flags.to_string() };
    }

    for (suffix, negated) in [("present?", false), ("blank?", true)] {
        if let Some(inner) = strip_suffix_dotted(expr, suffix) {
            return Resolver::Presence { receiver: Box::new(parse(inner)), negated };
        }
    }
    for (suffix, negated) in [("set?", false), ("unset?", true)] {
        if let Some(inner) = strip_suffix_dotted(expr, suffix) {
            return Resolver::Assignment { receiver: Box::new(parse(inner)), negated };
        }
    }

    if let Some((receiver, separator)) = match_string_call(expr, "split") {
        return Resolver::Split { receiver: Box::new(parse(receiver)), separator: separator.to_string() };
    }

    if let Some(inner) = strip_suffix_dotted(expr, "first") {
        return Resolver::First(Box::new(parse(inner)));
    }
    if let Some(inner) = strip_suffix_dotted(expr, "last") {
        return Resolver::Last(Box::new(parse(inner)));
    }

    if let Some((receiver, substring)) = match_string_call(expr, "start_with?") {
        return Resolver::StartsWith { receiver: Box::new(parse(receiver)), substring: substring.to_string() };
    }
    if let Some((receiver, substring)) = match_string_call(expr, "end_with?") {
        return Resolver::EndsWith { receiver: Box::new(parse(receiver)), substring: substring.to_string() };
    }

    // Last before the `Lookup` catch-all, matching `resolver.rb`.
    if let Some(node) = parse_block_opener(expr) {
        return node;
    }

    Resolver::Lookup(expr.to_string())
}

/// Block-opener suffixes, in the order Ruby's pattern alternates them.
const BLOCK_OPENERS: [(&str, Option<BlockMode>); 4] =
    [("all?", Some(BlockMode::All)), ("any?", Some(BlockMode::Any)), ("none?", Some(BlockMode::None)), ("find", None)];

/// Hand-matched `/\A(.+?)\.(all?|any?|none?|find)\s*\{\s*\|(\w+)\|\s*/m`: the earliest
/// `.suffix { |param|`, then a brace-balanced body. Only `find` may trail a dotted path.
fn parse_block_opener(expr: &str) -> Option<Resolver> {
    let bytes = expr.as_bytes();
    let mut best: Option<(usize, Option<BlockMode>, usize, String)> = None;

    for (suffix, mode) in BLOCK_OPENERS {
        let marker = format!(".{suffix}");
        let mut from = 0;
        while let Some(rel) = expr[from..].find(marker.as_str()) {
            let at = from + rel;
            from = at + 1;
            if at == 0 {
                continue;
            }
            let mut i = at + marker.len();
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i >= bytes.len() || bytes[i] != b'{' {
                continue;
            }
            i += 1;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i >= bytes.len() || bytes[i] != b'|' {
                continue;
            }
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && (bytes[j].is_ascii_alphanumeric() || bytes[j] == b'_') {
                j += 1;
            }
            if j == start || j >= bytes.len() || bytes[j] != b'|' {
                continue;
            }
            let mut body_start = j + 1;
            while body_start < bytes.len() && bytes[body_start].is_ascii_whitespace() {
                body_start += 1;
            }
            if best.as_ref().is_none_or(|(best_at, ..)| at < *best_at) {
                best = Some((at, mode, body_start, expr[start..j].to_string()));
            }
            break;
        }
    }

    let (at, mode, body_start, param) = best?;
    let body_end = matching_brace(expr, body_start)?;
    let receiver = Box::new(parse(&expr[..at]));
    let predicate = Box::new(super::evaluator::parse(expr[body_start..body_end].trim()));
    let trailing = expr[body_end + 1..].trim();

    match mode {
        None => {
            if !(trailing.is_empty() || trailing.starts_with('.')) {
                return None;
            }
            let path = if trailing.is_empty() { Vec::new() } else { trailing[1..].split('.').map(str::to_string).collect() };
            Some(Resolver::Find { receiver, param, predicate, path })
        }
        Some(mode) => {
            if !trailing.is_empty() {
                return None;
            }
            Some(Resolver::BlockPredicate { mode, receiver, param, predicate })
        }
    }
}

/// Index of the `}` closing the block whose body starts at `start`, honouring quotes.
fn matching_brace(expr: &str, start: usize) -> Option<usize> {
    let bytes = expr.as_bytes();
    let mut depth = 1;
    let mut quote: Option<u8> = None;
    let mut index = start;
    while index < bytes.len() {
        let ch = bytes[index];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            }
        } else if ch == b'"' || ch == b'\'' {
            quote = Some(ch);
        } else if ch == b'{' {
            depth += 1;
        } else if ch == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some(index);
            }
        }
        index += 1;
    }
    None
}

/// Strips a trailing `.suffix`, requiring a non-empty remainder. A newline in the remainder
/// refuses, as Ruby's newline-blind `(.+)` does for every pattern but `match?`'s `/m` one.
fn strip_suffix_dotted<'a>(expr: &'a str, suffix: &str) -> Option<&'a str> {
    let marker = format!(".{suffix}");
    let prefix = expr.strip_suffix(marker.as_str())?;
    if prefix.is_empty() || prefix.contains('\n') {
        None
    } else {
        Some(prefix)
    }
}

fn is_integer_literal(expr: &str) -> bool {
    let s = expr.strip_prefix('-').unwrap_or(expr);
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

fn is_float_literal(expr: &str) -> bool {
    // `\A-?\d*\.\d+\z`
    let s = expr.strip_prefix('-').unwrap_or(expr);
    let Some(dot) = s.find('.') else { return false };
    let (int_part, rest) = s.split_at(dot);
    let frac_part = &rest[1..];
    int_part.bytes().all(|b| b.is_ascii_digit()) && !frac_part.is_empty() && frac_part.bytes().all(|b| b.is_ascii_digit())
}

fn quoted(expr: &str) -> Option<&str> {
    if expr.len() < 2 {
        return None;
    }
    if expr.starts_with('"') && expr.ends_with('"') {
        return Some(&expr[1..expr.len() - 1]);
    }
    if expr.starts_with('\'') && expr.ends_with('\'') {
        return Some(&expr[1..expr.len() - 1]);
    }
    None
}

/// Elements of a bracketed literal, split on top-level commas only so nested
/// arrays and quoted commas stay whole.
fn array_elements(expr: &str) -> Option<Vec<String>> {
    if !(expr.starts_with('[') && expr.ends_with(']')) {
        return None;
    }

    let inner = expr[1..expr.len() - 1].trim();
    if inner.is_empty() {
        return Some(Vec::new());
    }

    let mut elements = Vec::new();
    let mut depth: i32 = 0;
    let mut quote: Option<char> = None;
    let mut current = String::new();

    for char in inner.chars() {
        if let Some(open) = quote {
            if char == open {
                quote = None;
            }
            current.push(char);
            continue;
        }

        match char {
            '"' | '\'' => quote = Some(char),
            '[' | '(' => depth += 1,
            ']' | ')' => depth -= 1,
            _ => {}
        }

        if char == ',' && depth == 0 {
            elements.push(current.trim().to_string());
            current = String::new();
        } else {
            current.push(char);
        }
    }
    elements.push(current.trim().to_string());

    Some(elements.into_iter().filter(|element| !element.is_empty()).collect())
}

fn split_addition(expr: &str) -> Option<(&str, &str)> {
    let index = top_level_index(expr, "+", |_| true)?;
    Some((expr[..index].trim(), expr[index + 1..].trim()))
}

fn match_suffix<'a>(expr: &'a str, suffixes: &[&'a str]) -> Option<(&'a str, &'a str)> {
    for suffix in suffixes {
        let marker = format!(".{suffix}");
        if let Some(prefix) = expr.strip_suffix(marker.as_str()) {
            return Some((prefix, suffix));
        }
    }
    None
}

/// Hand-matched `/\A(.+)\.match\?\(\/(.*)\/([a-z]*)\)\z/m`: the receiver is the longest prefix
/// (at least one character) that leaves a `/pattern/flags)` tail, the flags lowercase letters.
fn match_regex(expr: &str) -> Option<(&str, &str, &str)> {
    const MARKER: &str = ".match?(/";
    let body = expr.strip_suffix(')')?;
    let close = body.rfind('/')?;
    let flags = &body[close + 1..];
    if !flags.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let index = body[..close + 1].rmatch_indices(MARKER).map(|(i, _)| i).find(|i| *i > 0 && i + MARKER.len() <= close)?;
    Some((&expr[..index], &body[index + MARKER.len()..close], flags))
}

/// Hand-matched `/\A(.+)\.NAME\("([^"]*)"\)\z/`: the argument holds no quote, so the last `"`
/// opens it and `.NAME(` must sit directly before that quote.
fn match_string_call<'a>(expr: &'a str, name: &str) -> Option<(&'a str, &'a str)> {
    let body = expr.strip_suffix("\")")?;
    let open = body.rfind('"')?;
    let receiver = body[..open].strip_suffix(format!(".{name}(").as_str())?;
    if receiver.is_empty() || receiver.contains('\n') {
        return None;
    }
    Some((receiver, &body[open + 1..]))
}

/// Splits at the rightmost `marker` when the expression ends in `)`.
fn match_call<'a>(expr: &'a str, marker: &str) -> Option<(&'a str, &'a str)> {
    if !expr.ends_with(')') {
        return None;
    }
    let index = expr.rfind(marker)?;
    Some((&expr[..index], &expr[index + marker.len()..expr.len() - 1]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn regex_parts(node: Resolver) -> (Resolver, String, String) {
        match node {
            Resolver::MatchesRegex { receiver, pattern, flags } => (*receiver, pattern, flags),
            other => panic!("expected MatchesRegex, got {other:?}"),
        }
    }

    #[test]
    fn parses_match_with_its_pattern_kept_verbatim() {
        let text = r"value.to_s.match?(/\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/)";
        let (receiver, pattern, flags) = regex_parts(parse(text));

        assert!(matches!(receiver, Resolver::ToS(_)));
        assert_eq!(pattern, r"\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z");
        assert_eq!(flags, "");
    }

    #[test]
    fn keeps_the_flags_and_a_slash_inside_the_pattern() {
        let (_, pattern, flags) = regex_parts(parse("name.match?(/a\\/b/i)"));

        assert_eq!(pattern, "a\\/b");
        assert_eq!(flags, "i");
    }

    #[test]
    fn leaves_a_call_that_is_not_a_regex_match_a_lookup() {
        assert!(matches!(parse("name.match?(other)"), Resolver::Lookup(_)));
    }

    /// The emitted JSON with its pretty-printing whitespace removed (no test string has spaces).
    fn compact(text: &str) -> String {
        crate::emit::write(&crate::expr::ast_json::emit_predicate(text)).split_whitespace().collect()
    }

    #[test]
    fn present_and_blank_are_one_node_told_apart_by_negated() {
        assert!(matches!(parse("name.present?"), Resolver::Presence { negated: false, .. }));
        assert!(matches!(parse("name.blank?"), Resolver::Presence { negated: true, .. }));
    }

    #[test]
    fn set_and_unset_are_one_node_told_apart_by_negated() {
        assert!(matches!(parse("note.set?"), Resolver::Assignment { negated: false, .. }));
        assert!(matches!(parse("note.unset?"), Resolver::Assignment { negated: true, .. }));
    }

    #[test]
    fn split_keeps_its_separator_verbatim_and_chains_into_first_and_last() {
        let Resolver::First(inner) = parse("path.split(\"/\").first") else { panic!("expected First") };
        let Resolver::Split { receiver, separator } = *inner else { panic!("expected Split") };
        assert_eq!(separator, "/");
        assert!(matches!(*receiver, Resolver::Lookup(_)));
        assert!(matches!(parse("path.split(\"::\").last"), Resolver::Last(_)));
    }

    #[test]
    fn start_and_end_with_take_a_quoted_argument() {
        let Resolver::StartsWith { substring, .. } = parse("branch.value.start_with?(\"qa/\")") else { panic!() };
        assert_eq!(substring, "qa/");
        let Resolver::EndsWith { substring, .. } = parse("name.end_with?(\"x, y\")") else { panic!() };
        assert_eq!(substring, "x, y");
    }

    #[test]
    fn a_call_without_a_quoted_argument_stays_a_lookup() {
        assert!(matches!(parse("name.start_with?(prefix)"), Resolver::Lookup(_)));
        assert!(matches!(parse("name.split(sep)"), Resolver::Lookup(_)));
        assert!(matches!(parse("name.split(\"a\"b\")"), Resolver::Lookup(_)));
    }

    #[test]
    fn emits_ruby_key_order_for_each_new_node() {
        let a = r#"{"op":"lookup","path":["a"]}"#;
        let cases = [
            ("a.present?", format!(r#"{{"op":"presence","receiver":{a},"negated":false}}"#)),
            ("a.blank?", format!(r#"{{"op":"presence","receiver":{a},"negated":true}}"#)),
            ("a.set?", format!(r#"{{"op":"assignment","receiver":{a},"negated":false}}"#)),
            ("a.unset?", format!(r#"{{"op":"assignment","receiver":{a},"negated":true}}"#)),
            ("a.split(\"/\")", format!(r#"{{"op":"split","receiver":{a},"separator":"/"}}"#)),
            ("a.first", format!(r#"{{"op":"first","receiver":{a}}}"#)),
            ("a.last", format!(r#"{{"op":"last","receiver":{a}}}"#)),
            ("a.start_with?(\"x\")", format!(r#"{{"op":"starts_with","receiver":{a},"substring":"x"}}"#)),
            ("a.end_with?(\"y\")", format!(r#"{{"op":"ends_with","receiver":{a},"substring":"y"}}"#)),
        ];
        for (text, expected) in cases {
            assert_eq!(compact(text), expected, "{text}");
        }
    }
}
