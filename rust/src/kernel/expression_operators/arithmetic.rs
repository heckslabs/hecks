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

#[cfg(test)]
mod sum_tests {
    use super::sum;
    use crate::kernel::expr::Value;

    #[test]
    fn adds_ordinary_ints() {
        assert_eq!(sum(&Value::Int(2), &Value::Int(3)).unwrap(), Value::Int(5));
    }

    #[test]
    fn mixed_int_float_promotes_to_float_like_ruby_coercion() {
        assert_eq!(sum(&Value::Int(2), &Value::Float(3.5)).unwrap(), Value::Float(5.5));
    }

    // L22: `Int + Int` used plain `+`, which panics in debug and silently
    // wraps in release — neither matches Ruby's `Integer#+`, which
    // promotes to Bignum and never overflows. True Bignum parity isn't
    // achievable without a bignum dependency (this kernel has none, by
    // design); refusing cleanly on overflow is the honest fix.
    #[test]
    fn refuses_cleanly_on_overflow_instead_of_panicking_or_wrapping() {
        let result = sum(&Value::Int(i64::MAX), &Value::Int(1));
        assert!(result.is_err(), "i64::MAX + 1 must refuse, not silently wrap to i64::MIN");
    }

    #[test]
    fn refuses_cleanly_on_negative_overflow() {
        let result = sum(&Value::Int(i64::MIN), &Value::Int(-1));
        assert!(result.is_err(), "i64::MIN + -1 must refuse, not silently wrap to i64::MAX");
    }

    #[test]
    fn does_not_refuse_right_at_the_boundary() {
        assert_eq!(sum(&Value::Int(i64::MAX - 1), &Value::Int(1)).unwrap(), Value::Int(i64::MAX));
    }
}

// Ruby's `Integer#+` (resolver.rb's `add`, read directly: plain `+`) never
// overflows — `Integer` promotes to Bignum with no ceiling. This kernel's
// `Value::Int` is a plain `i64` (zero Cargo dependencies — no
// arbitrary-precision integer type lives anywhere in this crate, see
// `rust/src/kernel/json.rs`'s own header for the same constraint), so true
// Bignum parity isn't achievable here without a real bignum dependency.
// Rust's own unchecked `+` on `i64` is wrong either way it could go: it
// panics in a debug build (an uncontrolled crash, not a refusal) and
// silently WRAPS in a release build (`i64::MAX + 1` becomes `i64::MIN` —
// corrupted data, not even a plausible-looking wrong number). `checked_add`
// plus a clean refusal is the honest middle ground used elsewhere in this
// file (`modulo`'s divide-by-zero check, above): refuse loudly and
// specifically rather than silently corrupt OR crash uncontrolled.
fn sum(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return l.checked_add(*r).map(Value::Int).ok_or_else(|| eval_error(format!("addition overflowed: {l} + {r} does not fit in a 64-bit integer")));
    }
    let l = require_number(lhs, "addition")?;
    let r = require_number(rhs, "addition")?;
    Ok(Value::Float(l + r))
}

/// Shared with `sign_test.rs` — see this file's own header.
pub fn require_number(v: &Value, operation: &str) -> Result<f64, Refusal> {
    scalar::numeric(v).ok_or_else(|| eval_error(format!("{operation} expects a number, got {v:?}")))
}
