// Implements the Ruby grammar's "comparison" expression-operator category
// (projection.json: `>=`, `<=`, `<`, `>`, `==`, `!=` — six symbols) —
// `Evaluator::Operator`/`Evaluator.apply`/`.less_than`/`.equal?`
// (evaluator.rb), read directly: six comparison symbols reduced to two
// primitives (`less_than`, `equal`) OR'd together, negated per operator,
// rather than one code path per symbol. `Comparison` is that primitive
// pair plus the negation flag — the exact structural mirror of Ruby's
// `Operator` struct, minus the `symbol` field itself (nothing here ever
// needs to print which of the six symbols produced a given `Comparison`,
// only what it computes).
//
// `sign_test.rs` REUSES `apply`/`Comparison` from here rather than
// re-deriving the same primitives a second time — the identical reuse
// `Resolver.sign_test_node`'s own `Evaluator::OPERATORS.find` performs on
// the Ruby side (a sign test is sugar for comparing against literal 0
// through this SAME algebra, not a separate one).
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `Compare` — see `logical.rs`'s header for why the trailing
// arm is a router-bug guard, not a real refusal path.

use crate::kernel::attribute_shapes::scalar;
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

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

/// The algebra itself, on values already resolved — mirrors
/// `Evaluator.apply` exactly: OR the two primitives together, negate if
/// the operator says to. Public so `sign_test.rs` can apply the SAME
/// primitives against the literal 0 rather than re-deriving
/// positive?/negative?/zero? by hand a second time.
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

fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (scalar::numeric(lhs), scalar::numeric(rhs)) {
        (Some(l), Some(r)) => l == r,
        _ => lhs == rhs,
    }
}
