//! conception_kernel::recognize — parse a `given` expression into a
//! `Precondition` (the parse-shape half of the data layer).
//!
//! Faithful to `behaviors_conceiver/generator.rs::parse_precondition` for the
//! kinds this slice covers. Size-checks are tried BEFORE equality so
//! `field.size > 0` is not mis-read. Shapes outside the slice (integer
//! inequalities, opaque givens) return None — the caller skips them; this
//! kernel runs parallel to generator.rs, so None here is "not my slice", not
//! "dropped from the suite".
//!
//! Example:
//!   assert_eq!(parse_given("items.empty?").unwrap().kind, Kind::EmptyList);

use super::grammar::{Kind, Precondition};

/// Recognize a `given` as one of this slice's kinds, or None.
pub fn parse_given(expr: &str) -> Option<Precondition> {
    if let Some(p) = parse_size_check(expr) {
        return Some(p);
    }
    parse_equality(expr)
}

/// `field.any?`, `field.empty?`, or `field.size <op> <n>` mapped to a list kind.
fn parse_size_check(expr: &str) -> Option<Precondition> {
    let trimmed = expr.trim().trim_end_matches('}').trim();
    if let Some(field) = trimmed.strip_suffix(".any?") {
        return list_pre(field, Kind::NonEmptyList, 1);
    }
    if let Some(field) = trimmed.strip_suffix(".empty?") {
        return list_pre(field, Kind::EmptyList, 0);
    }
    let dot = trimmed.find(".size")?;
    let field = trimmed[..dot].trim();
    if !is_simple_field(field) {
        return None;
    }
    let rest = trimmed[dot + 5..].trim();
    for (op, tag) in &[(">=", "gte"), ("<=", "lte"), (">", "gt"), ("<", "lt"), ("==", "eq")] {
        if !rest.starts_with(op) {
            continue;
        }
        let raw = rest[op.len()..].trim();
        let n: i64 = raw.parse().ok()?;
        return match *tag {
            // size > 0 / size >= 1 — one Append satisfies.
            "gt" if n == 0 => list_pre(field, Kind::NonEmptyList, 1),
            "gte" if n == 1 => list_pre(field, Kind::NonEmptyList, 1),
            // size >= N (N>=2) carries N; size > N (N>=1) carries N+1.
            "gte" if n >= 2 => list_pre(field, Kind::MinSizeList, n),
            "gt" if n >= 1 => list_pre(field, Kind::MinSizeList, n + 1),
            // empty? / size == 0 / size < N (N>=1) — the empty default holds.
            "eq" if n == 0 => list_pre(field, Kind::EmptyList, 0),
            "lt" if n >= 1 => list_pre(field, Kind::EmptyList, 0),
            _ => None,
        };
    }
    None
}

/// `field == "value"`, `== :sym`, `== true/false`, or `== <int>`.
fn parse_equality(expr: &str) -> Option<Precondition> {
    let parts: Vec<&str> = expr.splitn(2, "==").collect();
    if parts.len() != 2 {
        return None;
    }
    let field = parts[0].trim();
    if !is_simple_field(field) {
        return None;
    }
    let raw = parts[1].trim().trim_end_matches('}').trim();
    let value = if raw.starts_with('"') {
        let end = raw[1..].find('"')? + 1;
        raw[1..end].to_string()
    } else if let Some(sym) = raw.strip_prefix(':') {
        let end = sym
            .find(|c: char| !c.is_alphanumeric() && c != '_')
            .unwrap_or(sym.len());
        sym[..end].to_string()
    } else if raw == "true" || raw == "false" || raw.parse::<i64>().is_ok() {
        raw.to_string()
    } else {
        return None;
    };
    Some(Precondition {
        kind: Kind::Equals,
        field: field.to_string(),
        count: 0,
        value,
    })
}

fn list_pre(field: &str, kind: Kind, count: i64) -> Option<Precondition> {
    let field = field.trim();
    if !is_simple_field(field) {
        return None;
    }
    Some(Precondition {
        kind,
        field: field.to_string(),
        count,
        value: String::new(),
    })
}

fn is_simple_field(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || c == '_')
}
