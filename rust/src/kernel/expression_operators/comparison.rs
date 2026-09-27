//! `>=`, `<=`, `<`, `>`, `==`, `!=` (`Evaluator.apply`), reduced to two primitives plus negation.

use crate::kernel::attribute_shapes::scalar;
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

/// The comparison algebra: `less_than` and `equal` OR'd together, negated when `negated`.
#[derive(Debug, Clone, Copy)]
pub struct Comparison {
    pub less_than: bool,
    pub equal: bool,
    pub negated: bool,
}

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Compare { op, left, right } = expr else {
        return Err(Refusal::TypeMismatch(format!("comparison::interpret called with a non-comparison node {expr:?} — a router bug")));
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
            _ => Err(eval_error(format!("comparison of {lhs:?} with {rhs:?} failed"))),
        },
    }
}

/// `pub(crate)` so `membership.rs` reuses the numeric-coerced equality for array haystacks.
pub(crate) fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (scalar::numeric(lhs), scalar::numeric(rhs)) {
        (Some(l), Some(r)) => l == r,
        _ => lhs == rhs,
    }
}
