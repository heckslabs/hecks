//! conception_kernel::recognize — parse a `given` expression into a
//! `Precondition` (the parse-shape half of the data layer).
//!
//! Faithful to `behaviors_conceiver/generator.rs::parse_precondition`, in the
//! same order: size-checks BEFORE equality BEFORE inequality, so `field.size > 0`
//! is not mis-read as an integer inequality. Shapes outside the taxonomy
//! (`<=`, opaque givens) return None — the caller skips them.
//!
//! Example:
//!   assert_eq!(parse_given("quantity > 2").unwrap().kind, Kind::GreaterThan);
//!   assert_eq!(parse_given("items.empty?").unwrap().kind, Kind::EmptyList);

use super::grammar::{Kind, Precondition};

/// Recognize a `given` as one of the taxonomy's kinds, or None.
pub fn parse_given(expr: &str) -> Option<Precondition> {
    if let Some(p) = parse_size_check(expr) {
        return Some(p);
    }
    if let Some(p) = parse_equality(expr) {
        return Some(p);
    }
    parse_inequality(expr)
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
            "gt" if n == 0 => list_pre(field, Kind::NonEmptyList, 1),
            "gte" if n == 1 => list_pre(field, Kind::NonEmptyList, 1),
            "gte" if n >= 2 => list_pre(field, Kind::MinSizeList, n),
            "gt" if n >= 1 => list_pre(field, Kind::MinSizeList, n + 1),
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
        target: 0,
        value,
    })
}

/// `field > n`, `field >= n`, `field < n` (bare integer RHS). `<=` is outside
/// the taxonomy (too easy to overshoot) — None. Carries `target`, the value a
/// producer must land the field at: n+1 (gt), n (gte), n-1 (lt).
fn parse_inequality(expr: &str) -> Option<Precondition> {
    let trimmed = expr.trim().trim_end_matches('}').trim();
    for (op, kind, delta) in &[
        (">=", Kind::GreaterOrEqual, 0_i64),
        (">", Kind::GreaterThan, 1),
        ("<", Kind::LessThan, -1),
    ] {
        if !trimmed.contains(op) {
            continue;
        }
        if *op == ">" && trimmed.contains(">=") {
            continue;
        }
        if *op == "<" && trimmed.contains("<=") {
            continue;
        }
        let parts: Vec<&str> = trimmed.splitn(2, op).collect();
        if parts.len() != 2 {
            continue;
        }
        let field = parts[0].trim();
        if !is_simple_field(field) {
            continue;
        }
        let n: i64 = parts[1].trim().parse().ok()?;
        return Some(Precondition {
            kind: *kind,
            field: field.to_string(),
            count: n,
            target: n + delta,
            value: String::new(),
        });
    }
    None
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
        target: 0,
        value: String::new(),
    })
}

fn is_simple_field(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || c == '_')
}
