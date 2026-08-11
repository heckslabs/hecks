// Implements the Ruby grammar's "arithmetic" expression-operator category
// (projection.json: `+`, `.modulo` — two symbols, two distinct
// interpreter nodes) — `Resolver::Addition`/`Resolver::Modulo`
// (resolver.rb's `add`), read directly. Both symbols require their
// operands to be numeric (`Resolver.numeric`, mirrored here by
// `attribute_shapes::scalar::numeric` — the "scalar" attribute shape is
// exactly what a number is), so `require_number` is shared between them
// rather than checked twice.
//
// `sign_test.rs` also imports `require_number` from here — a sign test's
// own receiver must be numeric for the identical reason an operand to
// `+`/`.modulo` must be, so it reuses this check rather than repeating it.
//
// `expr.rs`'s `category_of` guarantees `add`/`modulo` below are only ever
// called with `Add`/`Modulo` respectively — see `logical.rs`'s header for
// why each trailing arm is a router-bug guard, not a real refusal path.

use crate::kernel::attribute_shapes::scalar;
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn add(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Add(l, r) = expr else {
        return Err(Refusal::TypeMismatch(format!("arithmetic::add called with a non-addition node {expr:?} — a router bug")));
    };

    sum(&eval(l, ctx)?, &eval(r, ctx)?)
}

pub fn modulo(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Modulo { receiver, divisor } = expr else {
        return Err(Refusal::TypeMismatch(format!("arithmetic::modulo called with a non-modulo node {expr:?} — a router bug")));
    };

    let r = require_number(&eval(receiver, ctx)?, "modulo")?.trunc() as i64;
    let d = require_number(&eval(divisor, ctx)?, "modulo")?.trunc() as i64;
    if d == 0 {
        return Err(eval_error("divided by 0".to_string()));
    }
    Ok(Value::Int(r % d))
}

fn sum(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return Ok(Value::Int(l + r));
    }
    let l = require_number(lhs, "addition")?;
    let r = require_number(rhs, "addition")?;
    Ok(Value::Float(l + r))
}

/// Shared with `sign_test.rs` — see this file's own header.
pub fn require_number(v: &Value, operation: &str) -> Result<f64, Refusal> {
    scalar::numeric(v).ok_or_else(|| eval_error(format!("{operation} expects a number, got {v:?}")))
}
