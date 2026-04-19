//! HecksalInterpreter — evaluates givens and applies mutations
//!
//! The expression evaluator for Bluebook's declarative behavior.
//! Givens are predicates. Mutations are state changes. Both are data.
//!
//! Usage:
//!   check_givens(cmd, state, attrs)?;
//!   apply_mutations(cmd, state, attrs);

use super::{AggregateState, RuntimeError, Value};
use crate::ir::{Command, MutationOp};
use std::collections::HashMap;

pub fn check_givens(
    cmd: &Command,
    state: &AggregateState,
    attrs: &HashMap<String, Value>,
) -> Result<(), RuntimeError> {
    for given in &cmd.givens {
        if !evaluate_given(&given.expression, state, attrs) {
            return Err(RuntimeError::GivenFailed {
                message: given
                    .message
                    .clone()
                    .unwrap_or_else(|| given.expression.clone()),
                expression: given.expression.clone(),
            });
        }
    }
    Ok(())
}

pub fn apply_mutations(
    cmd: &Command,
    state: &mut AggregateState,
    attrs: &HashMap<String, Value>,
) {
    for mutation in &cmd.mutations {
        match mutation.operation {
            MutationOp::Set => {
                let val = resolve_mutation_value(&mutation.value, attrs, state);
                state.set(&mutation.field, val);
            }
            MutationOp::Append => {
                let val = resolve_mutation_value(&mutation.value, attrs, state);
                state.append(&mutation.field, val);
            }
            MutationOp::Increment => {
                let amount = resolve_mutation_value(&mutation.value, attrs, state)
                    .as_int()
                    .unwrap_or(1);
                state.increment(&mutation.field, amount);
            }
            MutationOp::Decrement => {
                let amount = resolve_mutation_value(&mutation.value, attrs, state)
                    .as_int()
                    .unwrap_or(1);
                state.decrement(&mutation.field, amount);
            }
            MutationOp::Toggle => {
                state.toggle(&mutation.field);
            }
        }
    }
}

fn evaluate_given(
    expr: &str,
    state: &AggregateState,
    attrs: &HashMap<String, Value>,
) -> bool {
    let expr = expr.trim();

    // `field.any?` → field.size > 0; `field.empty?` → field.size == 0.
    // Ruby idioms used in handwritten bluebooks; rewrite to runtime
    // primitives so the comparison evaluator below handles them.
    if let Some(field) = expr.strip_suffix(".any?") {
        let val = resolve_expr(&format!("{}.size", field.trim()), state, attrs);
        return compare_lt(&Value::Int(0), &val);
    }
    if let Some(field) = expr.strip_suffix(".empty?") {
        let val = resolve_expr(&format!("{}.size", field.trim()), state, attrs);
        return values_equal(&val, &Value::Int(0));
    }

    // Order matters: check `>=`/`<=` BEFORE `>`/`<` so the longer
    // operator wins. The split_comparison helpers also bail out on the
    // shorter operator when the longer is present.
    if let Some((lhs, rhs)) = split_comparison(expr, ">=") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return !compare_lt(&left, &right);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "<=") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return !compare_lt(&right, &left);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "<") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return compare_lt(&left, &right);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, ">") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return compare_lt(&right, &left);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "==") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return values_equal(&left, &right);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "!=") {
        let left = resolve_expr(lhs.trim(), state, attrs);
        let right = resolve_expr(rhs.trim(), state, attrs);
        return !values_equal(&left, &right);
    }

    true
}

fn resolve_expr(expr: &str, state: &AggregateState, attrs: &HashMap<String, Value>) -> Value {
    if let Ok(n) = expr.parse::<i64>() {
        return Value::Int(n);
    }
    if expr.starts_with('"') && expr.ends_with('"') {
        return Value::Str(expr[1..expr.len() - 1].to_string());
    }
    if expr == "true" {
        return Value::Bool(true);
    }
    if expr == "false" {
        return Value::Bool(false);
    }
    if expr.ends_with(".size") {
        let field = &expr[..expr.len() - 5];
        let val = attrs.get(field)
            .cloned()
            .unwrap_or_else(|| state.get(field).clone());
        return match val {
            Value::List(v) => Value::Int(v.len() as i64),
            Value::Str(s) => Value::Int(s.len() as i64),
            _ => Value::Int(0),
        };
    }
    // Command attributes shadow state when they share a name — the
    // `given` clause runs at dispatch time with the inbound input
    // already in scope, mirroring how Ruby's predicate DSL evaluates
    // against a binding that includes both attrs and state.
    if let Some(v) = attrs.get(expr) {
        return v.clone();
    }
    state.get(expr).clone()
}

fn split_comparison<'a>(expr: &'a str, op: &str) -> Option<(&'a str, &'a str)> {
    // Disambiguate single-char ops from their multi-char counterparts.
    // `<` must not match against `<=` or `<` inside `!=`/`==`/`>=`.
    if op == "<" && (expr.contains("<=") || expr.contains("<<")) {
        return None;
    }
    if op == ">" && (expr.contains(">=") || expr.contains(">>")) {
        return None;
    }
    if op == "=" {
        return None; // Bare `=` isn't a comparison; force callers to use ==.
    }
    let idx = expr.find(op)?;
    // For ==/!=, ensure we're not confusing them with =/= prefixes; find
    // returns the first occurrence of the literal substring so this is OK.
    Some((&expr[..idx], &expr[idx + op.len()..]))
}

/// Loose equality: Bool(true) == Str("true"), Int(42) == Str("42").
/// Numeric coercion lets `Int(0) == Str("0")`, `Int(0) == Null` (Null
/// stands in for an unset numeric attr), and `Str("1.0") == Int(1)`
/// (Float values stored as strings still compare to whole-number ints).
fn values_equal(left: &Value, right: &Value) -> bool {
    if left == right {
        return true;
    }
    if let (Some(a), Some(b)) = (numeric_value(left), numeric_value(right)) {
        return a == b;
    }
    let ls = format!("{}", left);
    let rs = format!("{}", right);
    ls == rs
}

fn compare_lt(left: &Value, right: &Value) -> bool {
    // Try Int<Int first; fall back to numeric coercion through f64 so
    // Float-valued attrs (stored as Str("1.0")) and mixed Int/Str
    // comparisons (e.g. `amount > 0` where amount is Str("1.5")) work.
    if let (Value::Int(a), Value::Int(b)) = (left, right) { return a < b; }
    let l = numeric_value(left);
    let r = numeric_value(right);
    match (l, r) {
        (Some(a), Some(b)) => a < b,
        _ => false,
    }
}

/// Best-effort numeric coercion: Int as-is, Str parsed as f64, Bool to
/// 0/1, Null as 0 (an unset Integer attr behaves as zero). Returns None
/// for List/Map and unparseable strings.
fn numeric_value(v: &Value) -> Option<f64> {
    match v {
        Value::Int(n) => Some(*n as f64),
        Value::Bool(true) => Some(1.0),
        Value::Bool(false) => Some(0.0),
        Value::Str(s) => s.parse::<f64>().ok(),
        Value::Null => Some(0.0),
        _ => None,
    }
}

pub fn resolve_mutation_value(
    value_expr: &str,
    attrs: &HashMap<String, Value>,
    state: &AggregateState,
) -> Value {
    let value_expr = value_expr.trim();

    // Hash-like: { name: :name, amount: :amount }
    if value_expr.starts_with('{') && value_expr.ends_with('}') {
        let inner = &value_expr[1..value_expr.len() - 1];
        let mut map = HashMap::new();
        for pair in inner.split(',') {
            let pair = pair.trim();
            if let Some(colon) = pair.find(':') {
                let key = pair[..colon].trim().trim_start_matches(':');
                let val_ref = pair[colon + 1..].trim().trim_start_matches(':');
                let val = attrs
                    .get(val_ref)
                    .cloned()
                    .unwrap_or(Value::Str(val_ref.to_string()));
                map.insert(key.to_string(), val);
            }
        }
        return Value::Map(map);
    }

    // `:now` and `seconds_since(:field)` used to resolve here — both
    // reached into the system clock from inside the domain (DDD
    // anti-pattern). They're gone. Time is infrastructure: the caller
    // (test, hecksagon adapter, app) provides the timestamp as a
    // command attribute. The lifecycle_validator catches any bluebook
    // that tries to bring them back.

    if value_expr.starts_with(':') {
        let field = &value_expr[1..];
        // Try attrs first, then state fields
        return attrs.get(field)
            .or_else(|| state.fields.get(field))
            .cloned()
            .unwrap_or(Value::Null);
    }

    if let Ok(n) = value_expr.parse::<i64>() {
        return Value::Int(n);
    }

    if value_expr.starts_with('"') && value_expr.ends_with('"') {
        return Value::Str(value_expr[1..value_expr.len() - 1].to_string());
    }

    attrs
        .get(value_expr)
        .cloned()
        .unwrap_or(Value::Str(value_expr.to_string()))
}
