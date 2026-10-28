//! `>=`, `<=`, `<`, `>`, `==`, `!=` (`Evaluator.apply`), reduced to two primitives plus negation.

use crate::attribute_shapes::scalar;
use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::Refusal;

/// The comparison algebra: `less_than` and `equal` OR'd together, negated when `negated`.
#[derive(Debug, Clone, Copy)]
pub struct Comparison {
    pub less_than: bool,
    pub equal: bool,
    pub negated: bool,
}

/// Evaluates `<`, `==` and their negations.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Compare { op, left, right } = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "comparison::interpret called with a non-comparison node {expr:?} — a router bug"
        )));
    };

    let l = eval(left, ctx)?;
    let r = eval(right, ctx)?;
    Ok(Value::Bool(apply(op, &l, &r)?))
}

/// Applies `op` to resolved values; `sign_test.rs` reuses it against the literal 0.
pub fn apply(op: &Comparison, lhs: &Value, rhs: &Value) -> Result<bool, Refusal> {
    let lt = op.less_than && less_than(lhs, rhs)?;
    let eq = op.equal && values_equal(lhs, rhs);
    Ok(if op.negated { !(lt || eq) } else { lt || eq })
}

fn less_than(lhs: &Value, rhs: &Value) -> Result<bool, Refusal> {
    match (scalar::numeric(lhs), scalar::numeric(rhs)) {
        (Some(l), Some(r)) => Ok(l < r),
        _ => match (lhs, rhs) {
            (Value::Str(l), Value::Str(r)) => Ok(l < r),
            _ => Err(eval_error(format!(
                "comparison of {} with {} failed",
                ruby_class_of(lhs),
                describe(rhs)
            ))),
        },
    }
}

/// Names `value`'s class the way Ruby's `Evaluator.class_of` does: `nil` for nil, else the
/// Ruby class name (`Integer`, `Float`, `String`, `TrueClass`, `FalseClass`, `Array`).
const fn ruby_class_of(value: &Value) -> &'static str {
    match value {
        Value::Nil => "nil",
        Value::Int(_) => "Integer",
        Value::Float(_) => "Float",
        Value::Str(_) => "String",
        Value::Bool(true) => "TrueClass",
        Value::Bool(false) => "FalseClass",
        Value::List(_) | Value::Array(_) => "Array",
        // A value object's own class name is not in the data; Hash is the nearest honest answer.
        Value::Object(_) => "Hash",
    }
}

/// Renders `value` the way Ruby's `Rendering.describe` does: `nil`, JSON for an array, else
/// `inspect`. A length-only `List` carries no elements, so it renders as an empty array.
fn describe(value: &Value) -> String {
    match value {
        Value::Nil => "nil".to_string(),
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Float(f) => crate::ruby_float::to_s(*f),
        Value::Str(s) => format!("{s:?}"),
        Value::List(_) => "[]".to_string(),
        Value::Array(items) => {
            let parts: Vec<String> = items.iter().map(describe_json).collect();
            format!("[{}]", parts.join(","))
        }
        Value::Object(fields) => {
            let parts: Vec<String> = fields
                .iter()
                .map(|(key, field)| format!("{key:?}:{}", describe_json(field)))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

/// An array element as JSON: `null` for nil, else the same text `describe` gives.
fn describe_json(value: &Value) -> String {
    match value {
        Value::Nil => "null".to_string(),
        other => describe(other),
    }
}

/// An `Int` and a `Float` are equal only when the float is a whole number that is that integer.
fn int_equals_float(i: i64, f: f64) -> bool {
    f.is_finite()
        && f.fract() == 0.0
        && (-9.223_372_036_854_776e18..9.223_372_036_854_776e18).contains(&f)
        && f as i64 == i
}

/// Ruby's `==` after `Evaluator.equal?`: numbers compare across kinds exactly, and lists and
/// objects compare element by element with the same rule, so `[1] == [1.0]`. `pub(crate)` so
/// `membership.rs` reuses it for array haystacks.
#[allow(clippy::float_cmp)] // reason: Ruby's `Float#==` is exact, and this mirrors it.
pub(crate) fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (lhs, rhs) {
        (Value::Int(a), Value::Int(b)) => a == b,
        (Value::Int(i), Value::Float(f)) | (Value::Float(f), Value::Int(i)) => {
            int_equals_float(*i, *f)
        }
        (Value::Float(a), Value::Float(b)) => a == b,
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(x, y)| values_equal(x, y))
        }
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(key, x)| b.get(key).is_some_and(|y| values_equal(x, y)))
        }
        _ => lhs == rhs,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failure(lhs: &Value, rhs: &Value) -> String {
        match less_than(lhs, rhs) {
            Err(Refusal::Fault(message)) => message,
            other => format!("expected a Fault, got {other:?}"),
        }
    }

    #[test]
    fn ordering_against_nil_reads_like_ruby() {
        assert_eq!(
            failure(&Value::Int(0), &Value::Nil),
            "comparison of Integer with nil failed"
        );
    }

    #[test]
    fn mixed_kinds_name_the_ruby_class_then_inspect_the_other_side() {
        assert_eq!(
            failure(&Value::Str("a".into()), &Value::Int(5)),
            "comparison of String with 5 failed"
        );
        assert_eq!(
            failure(&Value::Nil, &Value::Str("a".into())),
            "comparison of nil with \"a\" failed"
        );
        assert_eq!(
            failure(
                &Value::Bool(true),
                &Value::Array(vec![Value::Int(1), Value::Nil])
            ),
            "comparison of TrueClass with [1,null] failed"
        );
    }

    #[test]
    fn equality_compares_nested_numbers_across_kinds_like_ruby() {
        assert!(values_equal(
            &Value::Array(vec![Value::Int(1)]),
            &Value::Array(vec![Value::Float(1.0)])
        ));
        assert!(!values_equal(
            &Value::Int(9_007_199_254_740_993),
            &Value::Float(9_007_199_254_740_992.0)
        ));
        assert!(values_equal(&Value::Int(3), &Value::Float(3.0)));
        assert!(!values_equal(&Value::Int(3), &Value::Float(3.5)));
    }
}
