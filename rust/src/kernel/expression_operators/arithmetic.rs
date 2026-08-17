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
    Ok(Value::Int(floored_mod(r, d)))
}

// Ruby's `Integer#%` (resolver.rb's `apply_modulo`, read directly:
// `receiver.to_i % divisor.to_i`) is FLOORED — the result takes the
// divisor's own sign (or 0), same as Ruby's `-7 % 3 == 2`. Rust's native
// `%` is TRUNCATED — the result takes the dividend's own sign (or 0), so
// `-7 % 3 == -1` in plain Rust. Item #7, whole-project table-unification
// survey — found as a real, live, silent semantic divergence for any
// negative operand; no real corpus predicate uses `.modulo` with one yet,
// which is exactly why nothing had caught it. Standard truncated→floored
// correction: add the divisor back when the truncated remainder is
// nonzero and its sign disagrees with the divisor's. Extracted to its own
// pure function (rather than inlined in `modulo` above) so it can be unit
// tested directly, without constructing an `Expr`/`EvalContext`.
fn floored_mod(r: i64, d: i64) -> i64 {
    let raw = r % d;
    if raw != 0 && (raw < 0) != (d < 0) { raw + d } else { raw }
}

#[cfg(test)]
mod tests {
    use super::floored_mod;

    // Every value here is a real `ruby -e 'puts X % Y'` result, checked
    // by hand before this test was written — see this function's own
    // comment for the full argument.
    #[test]
    fn matches_ruby_integer_modulo_across_every_sign_combination() {
        assert_eq!(floored_mod(7, 3), 1);
        assert_eq!(floored_mod(-7, 3), 2);
        assert_eq!(floored_mod(7, -3), -2);
        assert_eq!(floored_mod(-7, -3), -1);
        assert_eq!(floored_mod(0, 3), 0);
        assert_eq!(floored_mod(6, 3), 0);
        assert_eq!(floored_mod(-6, 3), 0);
    }
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
