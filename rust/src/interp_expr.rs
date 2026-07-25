//! interp_expr - resolve_expr, the ONE expression resolver: literals, dotted
//! value-object paths, .size / .length, .modulo(n), attrs-over-state binding.
//!
//! Ported from the Hecks interpreter floor (rust/src/runtime/interp_expr.rs and
//! interp_expr_ops.rs), operation for operation. Its Ruby twin is
//! lib/hecksagain/expression/resolver.rb - the two are written from the same
//! chapter (language/bluebook/expression.bluebook) and MUST agree. When they do
//! not, the chapter was ambiguous, and the chapter is what gets fixed.

use serde_json::{Map, Value};

pub type State = Map<String, Value>;

/// One expression string to one value.
pub fn resolve_expr(expr: &str, state: &State, attrs: &State) -> Value {
    let expr = expr.trim();

    // .length is the Ruby-flavoured alias for .size - one operation.
    if let Some(field) = expr.strip_suffix(".length") {
        return resolve_expr(&format!("{}.size", field.trim()), state, attrs);
    }

    if let Ok(n) = expr.parse::<i64>() {
        return Value::from(n);
    }
    // A float literal rides as a string: every comparison coerces through f64,
    // so it still compares correctly without needing its own variant.
    if expr.parse::<f64>().is_ok() {
        return Value::String(expr.to_string());
    }
    if is_quoted(expr) {
        return Value::String(expr[1..expr.len() - 1].to_string());
    }
    if expr == "true" {
        return Value::Bool(true);
    }
    if expr == "false" {
        return Value::Bool(false);
    }
    if expr == "nil" || expr == "null" {
        return Value::Null;
    }

    // .positive? / .negative? / .zero? - the sign predicates. One operation
    // shape: resolve the receiver numerically and compare against nought. They
    // read far better than `> 0` in a domain sentence, which is the whole
    // reason to admit an operator at all.
    //
    // A receiver with no numeric reading is NOT positive, NOT negative, and NOT
    // zero - all three answer false rather than coercing a missing attribute to
    // 0 and quietly reporting zero? as true.
    for test in ["positive?", "negative?", "zero?"] {
        let suffix = format!(".{}", test);
        if let Some(receiver) = expr.strip_suffix(&suffix) {
            let value = match numeric_value(&resolve_expr(receiver, state, attrs)) {
                Some(value) => value,
                None => return Value::Bool(false),
            };
            return Value::Bool(match test {
                "positive?" => value > 0.0,
                "negative?" => value < 0.0,
                _ => value == 0.0,
            });
        }
    }

    // tick.modulo(60) - the periodic-cadence gate. A non-positive divisor
    // short-circuits to 0 rather than panicking: in a daemon, firing every
    // tick beats dying.
    if let Some((receiver, argument)) = match_suffix_call(expr, ".modulo(") {
        let divisor = numeric_value(&resolve_expr(&argument, state, attrs)).unwrap_or(0.0) as i64;
        if divisor <= 0 {
            return Value::from(0i64);
        }
        let left = numeric_value(&resolve_expr(&receiver, state, attrs)).unwrap_or(0.0) as i64;
        return Value::from(left.rem_euclid(divisor));
    }

    if let Some(field) = expr.strip_suffix(".size") {
        return Value::from(size_of(&resolve_expr(field.trim(), state, attrs)));
    }

    lookup(expr, state, attrs)
}

pub fn is_quoted(expr: &str) -> bool {
    let bytes = expr.as_bytes();
    if bytes.len() < 2 {
        return false;
    }
    let first = bytes[0];
    let last = bytes[bytes.len() - 1];
    (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'')
}

fn size_of(value: &Value) -> i64 {
    match value {
        Value::Array(items) => items.len() as i64,
        Value::String(text) => text.chars().count() as i64,
        Value::Object(map) => map.len() as i64,
        _ => 0,
    }
}

/// Split `receiver.call(arg)` into its two halves.
pub fn match_suffix_call(expr: &str, marker: &str) -> Option<(String, String)> {
    if !expr.ends_with(')') {
        return None;
    }
    let index = expr.rfind(marker)?;
    let receiver = expr[..index].to_string();
    let argument = expr[index + marker.len()..expr.len() - 1].to_string();
    Some((receiver, argument))
}

/// A flat name, or a dotted path stepping into value-object maps.
fn lookup(expr: &str, state: &State, attrs: &State) -> Value {
    if !expr.contains('.') {
        return fetch(expr, state, attrs);
    }

    let mut segments = expr.split('.');
    let head = segments.next().unwrap_or_default();
    let mut current = fetch(head, state, attrs);

    for segment in segments {
        current = match current {
            Value::Object(map) => map.get(segment).cloned().unwrap_or(Value::Null),
            _ => return Value::Null,
        };
    }
    current
}

/// Input shadows state: a command attribute of the same name wins over the
/// aggregate's stored value.
fn fetch(name: &str, state: &State, attrs: &State) -> Value {
    attrs
        .get(name)
        .or_else(|| state.get(name))
        .cloned()
        .unwrap_or(Value::Null)
}

/// The numeric reading of a value, or None when it has none. A string that
/// looks like a number counts - the Ruby side coerces the same way.
pub fn numeric_value(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}
