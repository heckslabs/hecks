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
                let val = resolve_mutation_value(&mutation.value, attrs);
                state.set(&mutation.field, val);
            }
            MutationOp::Append => {
                let val = resolve_mutation_value(&mutation.value, attrs);
                state.append(&mutation.field, val);
            }
            MutationOp::Increment => {
                let amount = resolve_mutation_value(&mutation.value, attrs)
                    .as_int()
                    .unwrap_or(1);
                state.increment(&mutation.field, amount);
            }
            MutationOp::Decrement => {
                let amount = resolve_mutation_value(&mutation.value, attrs)
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
    _attrs: &HashMap<String, Value>,
) -> bool {
    let expr = expr.trim();

    if let Some((lhs, rhs)) = split_comparison(expr, "<") {
        let left = resolve_expr(lhs.trim(), state);
        let right = resolve_expr(rhs.trim(), state);
        return compare_lt(&left, &right);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, ">") {
        let left = resolve_expr(lhs.trim(), state);
        let right = resolve_expr(rhs.trim(), state);
        return compare_lt(&right, &left);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "==") {
        let left = resolve_expr(lhs.trim(), state);
        let right = resolve_expr(rhs.trim(), state);
        return values_equal(&left, &right);
    }
    if let Some((lhs, rhs)) = split_comparison(expr, "!=") {
        let left = resolve_expr(lhs.trim(), state);
        let right = resolve_expr(rhs.trim(), state);
        return !values_equal(&left, &right);
    }

    true
}

fn resolve_expr(expr: &str, state: &AggregateState) -> Value {
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
        return match state.get(field) {
            Value::List(v) => Value::Int(v.len() as i64),
            Value::Str(s) => Value::Int(s.len() as i64),
            _ => Value::Int(0),
        };
    }
    state.get(expr).clone()
}

fn split_comparison<'a>(expr: &'a str, op: &str) -> Option<(&'a str, &'a str)> {
    if op == "<" && expr.contains("<=") {
        return None;
    }
    if op == ">" && expr.contains(">=") {
        return None;
    }
    let idx = expr.find(op)?;
    Some((&expr[..idx], &expr[idx + op.len()..]))
}

/// Loose equality: Bool(true) == Str("true"), Int(42) == Str("42")
fn values_equal(left: &Value, right: &Value) -> bool {
    if left == right {
        return true;
    }
    let ls = format!("{}", left);
    let rs = format!("{}", right);
    ls == rs
}

fn compare_lt(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Int(a), Value::Int(b)) => a < b,
        _ => false,
    }
}

pub fn resolve_mutation_value(
    value_expr: &str,
    attrs: &HashMap<String, Value>,
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

    if value_expr.starts_with(':') {
        let field = &value_expr[1..];
        return attrs.get(field).cloned().unwrap_or(Value::Null);
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
