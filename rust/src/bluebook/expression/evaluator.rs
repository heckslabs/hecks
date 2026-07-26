//! interp_givens - one canonical expression to one verdict.
//!
//! Mirrors lib/hecksagain/expression/evaluator.rb, including its SPLIT ORDER,
//! which is the part that carries meaning:
//!
//!   ||  ->  &&  ->  .include?  ->  >= <= < > == !=  ->  leaves
//!
//! `a || b && c` means `a || (b && c)` only because || is split first. A
//! runtime that split && first would reach a different verdict on the same text
//! and look perfectly correct in isolation.
//!
//! Truthiness, equality and ordering are RUBY'S, not a convenient
//! approximation. An earlier reading treated 0 and "" as false and compared
//! everything through to_s, so `given { count }` fired when there were none and
//! `count == "1"` was true. Both runtimes shared that reading, which made them
//! agree and both be wrong - the worst outcome a parity harness can bless.

use crate::interp_expr::{
    class_of, describe, match_call, numeric_value, resolve_expr, Eval, State,
};
use serde_json::Value;

const COMPARISONS: [&str; 6] = [">=", "<=", "<", ">", "==", "!="];

pub fn evaluate_given(expr: &str, state: &State, attrs: &State) -> Eval<bool> {
    let expr = strip_parens(expr.trim());
    let expr = expr.as_str();

    if let Some((left, right)) = split_top_level(expr, "||") {
        return Ok(evaluate_given(&left, state, attrs)? || evaluate_given(&right, state, attrs)?);
    }
    if let Some((left, right)) = split_top_level(expr, "&&") {
        return Ok(evaluate_given(&left, state, attrs)? && evaluate_given(&right, state, attrs)?);
    }

    if let Some((haystack, needle)) = match_call(expr, ".include?(") {
        return includes(&haystack, &needle, state, attrs);
    }

    for operator in COMPARISONS {
        if let Some((left, right)) = split_comparison(expr, operator) {
            return compare(operator, &left, &right, state, attrs);
        }
    }

    Ok(truthy(&resolve_expr(expr, state, attrs)?))
}

fn compare(operator: &str, left: &str, right: &str, state: &State, attrs: &State) -> Eval<bool> {
    let lhs = resolve_expr(left, state, attrs)?;
    let rhs = resolve_expr(right, state, attrs)?;

    Ok(match operator {
        ">=" => !less_than(&lhs, &rhs)?,
        "<=" => less_than(&lhs, &rhs)? || values_equal(&lhs, &rhs),
        "<" => less_than(&lhs, &rhs)?,
        ">" => !less_than(&lhs, &rhs)? && !values_equal(&lhs, &rhs),
        "==" => values_equal(&lhs, &rhs),
        "!=" => !values_equal(&lhs, &rhs),
        _ => false,
    })
}

/// Ruby's rule: numbers order against numbers and strings against strings.
/// Anything else RAISES, exactly as `"abc" < 3` raises in Ruby. Coercing
/// through to_s would have made "10" < "9" true and called it a comparison.
fn less_than(lhs: &Value, rhs: &Value) -> Eval<bool> {
    if let (Some(left), Some(right)) = (numeric_value(lhs), numeric_value(rhs)) {
        return Ok(left < right);
    }
    if let (Value::String(left), Value::String(right)) = (lhs, rhs) {
        return Ok(left < right);
    }
    Err(format!(
        "comparison of {} with {} failed",
        class_of(lhs),
        describe(rhs)
    ))
}

/// Ruby's equality: 1 == 1.0 is true, 1 == "1" is false.
pub fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (numeric_value(lhs), numeric_value(rhs)) {
        (Some(left), Some(right)) => left == right,
        _ => lhs == rhs,
    }
}

/// Ruby's truthiness: ONLY nil and false are falsy. 0 is true. "" is true.
fn truthy(value: &Value) -> bool {
    !matches!(value, Value::Null | Value::Bool(false))
}

fn includes(haystack: &str, needle: &str, state: &State, attrs: &State) -> Eval<bool> {
    let wanted = resolve_expr(needle, state, attrs)?;

    Ok(match resolve_expr(haystack, state, attrs)? {
        Value::Array(items) => items.iter().any(|item| values_equal(item, &wanted)),
        Value::String(text) => match &wanted {
            Value::String(part) => text.contains(part.as_str()),
            _ => false,
        },
        _ => false,
    })
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
    top_level_index(expr, operator, false).map(|index| halves(expr, index, operator))
}

/// As above, but refuses a match that is really part of a longer operator
/// (`>` inside `>=`), which would split mid-comparison and invert the verdict.
pub fn split_comparison(expr: &str, operator: &str) -> Option<(String, String)> {
    top_level_index(expr, operator, true).map(|index| halves(expr, index, operator))
}

fn halves(expr: &str, index: usize, operator: &str) -> (String, String) {
    (
        expr[..index].trim().to_string(),
        expr[index + operator.len()..].trim().to_string(),
    )
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
    if operator.starts_with('=')
        && matches!(before, Some(b'<') | Some(b'>') | Some(b'!') | Some(b'='))
    {
        return true;
    }
    false
}
