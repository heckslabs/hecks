//! Port of `resolver.rb`'s `parse` step only — see `expr/mod.rs`'s own
//! header.

use super::{find_operator, top_level_index, Operator};

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

    Resolver::Lookup(expr.to_string())
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
