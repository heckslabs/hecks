//! interp_givens - evaluate_given, one canonical expression to one verdict.
//!
//! Ported from the Hecks interpreter floor (rust/src/runtime/interp_givens.rs),
//! including its SPLIT ORDER, which is the part that actually carries meaning:
//!
//!   ||  ->  &&  ->  .include?  ->  >= <= < > == !=  ->  leaves
//!
//! `a || b && c` means `a || (b && c)` only because || is split first. A
//! runtime that split && first would reach a different verdict on the same text
//! and look perfectly correct in isolation. Its Ruby twin is
//! lib/hecksagain/expression/evaluator.rb and splits in exactly this order.

use crate::interp_expr::{is_quoted, match_suffix_call, numeric_value, resolve_expr, State};
use serde_json::Value;

const COMPARISONS: [&str; 6] = [">=", "<=", "<", ">", "==", "!="];

pub fn evaluate_given(expr: &str, state: &State, attrs: &State) -> bool {
    let expr = strip_parens(expr.trim());
    let expr = expr.as_str();

    if let Some((left, right)) = split_top_level(expr, "||") {
        return evaluate_given(&left, state, attrs) || evaluate_given(&right, state, attrs);
    }
    if let Some((left, right)) = split_top_level(expr, "&&") {
        return evaluate_given(&left, state, attrs) && evaluate_given(&right, state, attrs);
    }

    if let Some((haystack, needle)) = match_suffix_call(expr, ".include?(") {
        return includes(&haystack, &needle, state, attrs);
    }

    for operator in COMPARISONS {
        if let Some((left, right)) = split_comparison(expr, operator) {
            return compare(operator, &left, &right, state, attrs);
        }
    }

    truthy(&resolve_expr(expr, state, attrs))
}

fn compare(operator: &str, left: &str, right: &str, state: &State, attrs: &State) -> bool {
    let lhs = resolve_expr(left, state, attrs);
    let rhs = resolve_expr(right, state, attrs);

    match operator {
        ">=" => !less_than(&lhs, &rhs),
        "<=" => less_than(&lhs, &rhs) || values_equal(&lhs, &rhs),
        "<" => less_than(&lhs, &rhs),
        ">" => !less_than(&lhs, &rhs) && !values_equal(&lhs, &rhs),
        "==" => values_equal(&lhs, &rhs),
        "!=" => !values_equal(&lhs, &rhs),
        _ => false,
    }
}

/// Numbers compare as numbers, anything else as text. Same rule both sides.
fn less_than(lhs: &Value, rhs: &Value) -> bool {
    match (numeric_value(lhs), numeric_value(rhs)) {
        (Some(a), Some(b)) => a < b,
        _ => plain_text(lhs) < plain_text(rhs),
    }
}

pub fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (numeric_value(lhs), numeric_value(rhs)) {
        (Some(a), Some(b)) => a == b,
        _ => plain_text(lhs) == plain_text(rhs),
    }
}

/// A string renders as itself, never with JSON quotes - otherwise
/// `status == "sold"` would compare `"sold"` against `sold` and never match.
fn plain_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

fn truthy(value: &Value) -> bool {
    match value {
        Value::Bool(b) => *b,
        Value::Null => false,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

fn includes(haystack: &str, needle: &str, state: &State, attrs: &State) -> bool {
    let wanted = plain_text(&resolve_expr(needle, state, attrs));

    match resolve_expr(haystack, state, attrs) {
        Value::Array(items) => items.iter().any(|item| plain_text(item) == wanted),
        Value::String(text) => text.split(',').any(|item| item.trim() == wanted),
        _ => false,
    }
}

/// Drop parens only when they wrap the WHOLE expression - `(a) && (b)` must
/// keep them or the split would lose a branch.
fn strip_parens(expr: &str) -> String {
    if !(expr.starts_with('(') && expr.ends_with(')')) {
        return expr.to_string();
    }

    let mut depth = 0i32;
    for (index, character) in expr.char_indices() {
        match character {
            '(' => depth += 1,
            ')' => depth -= 1,
            _ => {}
        }
        if depth == 0 && index < expr.len() - 1 {
            return expr.to_string();
        }
    }
    strip_parens(expr[1..expr.len() - 1].trim())
}

pub fn split_top_level(expr: &str, operator: &str) -> Option<(String, String)> {
    top_level_index(expr, operator, false).map(|index| {
        (
            expr[..index].trim().to_string(),
            expr[index + operator.len()..].trim().to_string(),
        )
    })
}

/// As above, but refuses a match that is really part of a longer operator
/// (`>` inside `>=`), which would split mid-comparison and invert the verdict.
pub fn split_comparison(expr: &str, operator: &str) -> Option<(String, String)> {
    top_level_index(expr, operator, true).map(|index| {
        (
            expr[..index].trim().to_string(),
            expr[index + operator.len()..].trim().to_string(),
        )
    })
}

fn top_level_index(expr: &str, operator: &str, guard_longer: bool) -> Option<usize> {
    let bytes = expr.as_bytes();
    let mut depth = 0i32;
    let mut quote: Option<u8> = None;
    let mut index = 0usize;

    while index < bytes.len() {
        let character = bytes[index];

        if let Some(open) = quote {
            if character == open {
                quote = None;
            }
        } else if character == b'"' || character == b'\'' {
            quote = Some(character);
        } else if character == b'(' {
            depth += 1;
        } else if character == b')' {
            depth -= 1;
        } else if depth == 0 && expr[index..].starts_with(operator) {
            if !guard_longer || !part_of_longer(expr, index, operator) {
                return Some(index);
            }
        }

        index += 1;
    }
    None
}

fn part_of_longer(expr: &str, index: usize, operator: &str) -> bool {
    let bytes = expr.as_bytes();
    let after = bytes.get(index + operator.len()).copied();
    let before = if index > 0 { bytes.get(index - 1).copied() } else { None };

    if after == Some(b'=') && !operator.ends_with('=') {
        return true;
    }
    if operator.starts_with('=') && matches!(before, Some(b'<') | Some(b'>') | Some(b'!') | Some(b'=')) {
        return true;
    }
    let _ = is_quoted(expr);
    false
}
