//! `+` and `.modulo` (`Resolver::Addition`/`Modulo`); both require numeric operands.

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

// Floored like Ruby's `Integer#%` (the result takes the divisor's sign); Rust's `%` truncates.
fn floored_mod(r: i64, d: i64) -> i64 {
    // `i64::MIN % -1` overflows in Rust's `%`; every integer model answers 0 (C3.3).
    if d == -1 {
        return 0;
    }
    let raw = r % d;
    if raw != 0 && (raw < 0) != (d < 0) { raw + d } else { raw }
}

#[cfg(test)]
mod tests {
    use super::floored_mod;

    // Expected values are real `ruby -e 'puts X % Y'` results.
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

    // C3.3 — `i64::MIN % -1` answers 0, never panics.
    #[test]
    fn i64_min_modulo_minus_one_is_zero() {
        assert_eq!(floored_mod(i64::MIN, -1), 0);
    }
}

#[cfg(test)]
mod float_sum_tests {
    use super::sum;
    use crate::kernel::expr::Value;

    // C3.4 — a Float sum that overflows to infinity faults rather than answering inf.
    #[test]
    fn refuses_a_float_sum_that_is_not_finite() {
        let result = sum(&Value::Float(1.0e308), &Value::Float(1.0e308));
        assert!(result.is_err(), "1e308 + 1e308 must fault, not answer inf");
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

    // Ruby's `Integer#+` promotes to Bignum and never overflows; this kernel has no bignum, so
    // overflow refuses instead of panicking or wrapping.
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

// Ruby's `Integer#+` promotes to Bignum; an `i64` cannot, so `checked_add` refuses on overflow
// instead of panicking (debug) or wrapping (release).
fn sum(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return l.checked_add(*r).map(Value::Int).ok_or_else(|| eval_error(format!("addition overflowed: {l} + {r} does not fit in a 64-bit integer")));
    }
    let l = require_number(lhs, "addition")?;
    let r = require_number(rhs, "addition")?;
    let sum = l + r;
    // C3.4 — a non-finite Float sum faults like an Integer overflow.
    if !sum.is_finite() {
        return Err(eval_error(format!("addition overflowed: {l} + {r} is not a finite number")));
    }
    Ok(Value::Float(sum))
}

/// Shared with `sign_test.rs` — see this file's own header.
pub fn require_number(v: &Value, operation: &str) -> Result<f64, Refusal> {
    scalar::numeric(v).ok_or_else(|| eval_error(format!("{operation} expects a number, got {v:?}")))
}
