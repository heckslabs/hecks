//! Port of `resolver.rb`'s `parse` step only — see `expr/mod.rs`'s own
//! header.

use super::evaluator::Evaluator;
use super::{find_operator, top_level_index, Operator};

/// `BLOCK_PREDICATE_MODES` (resolver/block_predicates.rb) — one node,
/// three spellings, exactly as Ruby keeps them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BlockMode {
    All,
    Any,
    None,
}

impl BlockMode {
    /// The `crate::kernel::BlockMode` variant name the emitter writes.
    pub fn rust_name(&self) -> &'static str {
        match self {
            BlockMode::All => "All",
            BlockMode::Any => "Any",
            BlockMode::None => "None",
        }
    }
}

#[derive(Debug, Clone)]
pub enum Resolver {
    IntegerLiteral(i64),
    FloatLiteral(f64),
    /// Sliced verbatim between the quote characters, exactly as
    /// `resolver.rb#parse`'s own `expr[1..-2]` does — no escape
    /// processing, matching the Ruby source precisely.
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
    /// `["active", "suspended"]` — a literal set, the haystack half of an
    /// `.include?`. Port of `resolver.rb`'s own `ArrayLiteral` (added
    /// alongside it, same commit family) — see that file's own header on
    /// why this exists at all.
    ArrayLiteral(Vec<Resolver>),
    /// `receiver.any? { |param| predicate }` and siblings — port of
    /// `Resolver::BlockPredicate`; the predicate is a whole
    /// Evaluator-level parse of the block body.
    BlockPredicate { mode: BlockMode, receiver: Box<Resolver>, param: String, predicate: Box<Evaluator> },
    /// `receiver.find { |param| predicate }.a.b` — port of `Resolver::Find`.
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

    // Last before the `Lookup` catch-all, exactly where `resolver.rb`'s
    // own `parse` tries `parse_block_opener`.
    if let Some(node) = parse_block_opener(expr) {
        return node;
    }

    Resolver::Lookup(expr.to_string())
}

/// The block-opener suffixes, in the alternation order Ruby's pattern
/// lists them (`BLOCK_OPENER_SUFFIXES`: the three modes, then `find`).
const BLOCK_OPENERS: [(&str, Option<BlockMode>); 4] =
    [("all?", Some(BlockMode::All)), ("any?", Some(BlockMode::Any)), ("none?", Some(BlockMode::None)), ("find", None)];

/// Port of `Resolver::parse_block_opener` — Ruby's
/// `/\A(.+?)\.(all?|any?|none?|find)\s*\{\s*\|(\w+)\|\s*/m`, matched
/// by hand: the EARLIEST `.suffix` (receiver at least one character,
/// the non-greedy `.+?`) that is followed by `{ |param| `, then the
/// brace-balanced body, then whatever trails the closing brace — which
/// for `find` may be a dotted projection path and for the three modes
/// must be nothing at all, or this is not a block opener.
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

/// Port of `Resolver::matching_brace` — the index of the `}` closing the
/// block whose body starts at `start` (depth already one), quotes
/// respected, `None` if the text runs out first.
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

/// `expr =~ /\A(.+)\.SUFFIX\z/` — strips a literal `.suffix` off the end,
/// requiring at least one character remain before it (Ruby's `(.+)`).
fn strip_suffix_dotted<'a>(expr: &'a str, suffix: &str) -> Option<&'a str> {
    let marker = format!(".{suffix}");
    let prefix = expr.strip_suffix(marker.as_str())?;
    if prefix.is_empty() {
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

/// Port of `resolver.rb`'s own `array_elements` — the elements of a
/// bracketed literal, or `None` if this isn't one. Splits on TOP-LEVEL
/// commas only — quote-aware and depth-aware, the same discipline
/// `split_addition` already applies, so a nested array or a comma inside
/// a string element stays whole rather than splitting the literal in
/// half.
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

/// `expr.rindex(marker)` + `expr.end_with?(")")` — the rightmost
/// occurrence of `marker`, with the whole expression ending in `)`.
fn match_call<'a>(expr: &'a str, marker: &str) -> Option<(&'a str, &'a str)> {
    if !expr.ends_with(')') {
        return None;
    }
    let index = expr.rfind(marker)?;
    Some((&expr[..index], &expr[index + marker.len()..expr.len() - 1]))
}
