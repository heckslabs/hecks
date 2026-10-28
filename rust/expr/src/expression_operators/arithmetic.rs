//! `+`, `-`, `*`, `/` and `.modulo` (`Resolver::Addition`, `Subtraction`, `Multiplication`,
//! `Division`, `Modulo`); all require numeric operands.

use crate::attribute_shapes::scalar;
use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::rendering;
use crate::Refusal;

/// `-`, `*`, `/` and `+`, each the counterpart of the Ruby `Resolver` operation of that name.
pub fn binary(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let (name, symbol, l, r) = match expr {
        Expr::Add(l, r) => ("addition", "+", l, r),
        Expr::Sub(l, r) => ("subtraction", "-", l, r),
        Expr::Mul(l, r) => ("multiplication", "*", l, r),
        Expr::Div(l, r) => ("division", "/", l, r),
        _ => {
            return Err(Refusal::TypeMismatch(format!(
                "arithmetic::binary called with a non-binary node {expr:?} — a router bug"
            )))
        }
    };
    let (left, right) = (eval(l, ctx)?, eval(r, ctx)?);
    match symbol {
        "+" => sum(&left, &right),
        "-" => checked(name, symbol, &left, &right, i64::checked_sub, |a, b| a - b),
        "*" => checked(name, symbol, &left, &right, i64::checked_mul, |a, b| a * b),
        _ => divide(&left, &right),
    }
}

// Integer operands use the checked operation; anything else is a Float result that must stay
// finite, as `add` does. Ruby promotes to Bignum; this kernel refuses instead.
fn checked(
    name: &str,
    symbol: &str,
    lhs: &Value,
    rhs: &Value,
    int_op: fn(i64, i64) -> Option<i64>,
    float_op: fn(f64, f64) -> f64,
) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return int_op(*l, *r).map(Value::Int).ok_or_else(|| {
            eval_error(format!(
                "{name} overflowed: {l} {symbol} {r} does not fit in a 64-bit integer"
            ))
        });
    }
    let l = require_number(lhs, name)?;
    let r = require_number(rhs, name)?;
    finite(name, symbol, (lhs, rhs), float_op(l, r))
}

// The operands are quoted as Ruby prints them: an Integer bare, a Float as `Float#to_s`.
fn finite(
    name: &str,
    symbol: &str,
    operands: (&Value, &Value),
    result: f64,
) -> Result<Value, Refusal> {
    if result.is_finite() {
        return Ok(Value::Float(result));
    }
    Err(eval_error(format!(
        "{name} overflowed: {} {symbol} {} is not a finite number",
        quoted(operands.0),
        quoted(operands.1)
    )))
}

fn quoted(v: &Value) -> String {
    match v {
        Value::Int(i) => i.to_string(),
        Value::Float(f) => crate::ruby_float::to_s(*f),
        other => format!("{other:?}"),
    }
}

// Integer division floors toward negative infinity, as Ruby's `Integer#/` does (Rust's `/`
// truncates). A zero divisor is the same fault `.modulo` raises.
fn divide(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    let r = require_number(rhs, "division")?;
    if r == 0.0 {
        return Err(eval_error("divided by 0".to_string()));
    }
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return floored_div(*l, *r).map(Value::Int).ok_or_else(|| {
            eval_error(format!(
                "division overflowed: {l} / {r} does not fit in a 64-bit integer"
            ))
        });
    }
    let l = require_number(lhs, "division")?;
    finite("division", "/", (lhs, rhs), l / r)
}

// `None` only for `i64::MIN / -1`, the one quotient that does not fit.
fn floored_div(l: i64, r: i64) -> Option<i64> {
    let quotient = l.checked_div(r)?;
    Some(if l % r != 0 && ((l < 0) != (r < 0)) {
        quotient - 1
    } else {
        quotient
    })
}

/// `a % b`: floored for integers, Ruby's `Float#%` otherwise; a zero divisor is a fault.
pub fn modulo(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Modulo { receiver, divisor } = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "arithmetic::modulo called with a non-modulo node {expr:?} — a router bug"
        )));
    };

    let receiver = eval(receiver, ctx)?;
    let divisor = eval(divisor, ctx)?;
    let x = require_number(&receiver, "modulo")?;
    let y = require_number(&divisor, "modulo")?;
    if y == 0.0 {
        return Err(eval_error("divided by 0".to_string()));
    }
    if let (Value::Int(r), Value::Int(d)) = (&receiver, &divisor) {
        return Ok(Value::Int(floored_mod(*r, *d)));
    }
    // Ruby's `Float#%` takes the divisor's sign; an infinite divisor leaves a finite receiver be.
    let remainder = if y.is_infinite() && !x.is_infinite() {
        x
    } else {
        x % y
    };
    Ok(Value::Float(if y * remainder < 0.0 {
        remainder + y
    } else {
        remainder
    }))
}

// Floored like Ruby's `Integer#%` (the result takes the divisor's sign); Rust's `%` truncates.
const fn floored_mod(r: i64, d: i64) -> i64 {
    // `i64::MIN % -1` overflows in Rust's `%`; every integer model answers 0 (C3.3).
    if d == -1 {
        return 0;
    }
    let raw = r % d;
    if raw != 0 && (raw < 0) != (d < 0) {
        raw + d
    } else {
        raw
    }
}

#[cfg(test)]
mod division_tests {
    use super::{checked, divide, floored_div};
    use crate::expr::Value;

    #[test]
    fn floors_toward_negative_infinity_across_every_sign_combination() {
        // Real `ruby -e 'puts X / Y'` results.
        assert_eq!(floored_div(7, 2), Some(3));
        assert_eq!(floored_div(-7, 2), Some(-4));
        assert_eq!(floored_div(7, -2), Some(-4));
        assert_eq!(floored_div(-7, -2), Some(3));
        assert_eq!(floored_div(-6, 2), Some(-3));
        assert_eq!(floored_div(0, -5), Some(0));
    }

    #[test]
    fn a_money_percentage_rounds_down() {
        let product = checked(
            "multiplication",
            "*",
            &Value::Int(10801),
            &Value::Int(50),
            i64::checked_mul,
            |a, b| a * b,
        )
        .unwrap();

        assert_eq!(
            divide(&product, &Value::Int(100)).unwrap(),
            Value::Int(5400)
        );
    }

    #[test]
    fn a_zero_divisor_is_a_fault_not_a_crash() {
        assert!(divide(&Value::Int(1), &Value::Int(0)).is_err());
        assert!(divide(&Value::Float(1.0), &Value::Float(0.0)).is_err());
    }

    #[test]
    fn the_one_unrepresentable_quotient_is_a_fault() {
        assert!(divide(&Value::Int(i64::MIN), &Value::Int(-1)).is_err());
    }

    #[test]
    fn overflowing_products_and_differences_are_faults() {
        assert!(checked(
            "multiplication",
            "*",
            &Value::Int(i64::MAX),
            &Value::Int(2),
            i64::checked_mul,
            |a, b| a * b
        )
        .is_err());
        assert!(checked(
            "subtraction",
            "-",
            &Value::Int(i64::MIN),
            &Value::Int(1),
            i64::checked_sub,
            |a, b| a - b
        )
        .is_err());
    }
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
    use crate::expr::Value;

    // C3.4 — a Float sum that overflows to infinity faults rather than answering inf.
    #[test]
    fn refuses_a_float_sum_that_is_not_finite() {
        let result = sum(&Value::Float(1.0e308), &Value::Float(1.0e308));
        assert!(result.is_err(), "1e308 + 1e308 must fault, not answer inf");
    }

    // The fault quotes operands as Ruby prints them, not as Rust's 309-digit expansion.
    #[test]
    fn quotes_the_operands_in_rubys_float_format() {
        let fault = sum(&Value::Float(1.0e308), &Value::Float(1.0e308)).unwrap_err();
        assert_eq!(
            fault,
            crate::Refusal::Fault(
                "addition overflowed: 1.0e+308 + 1.0e+308 is not a finite number".to_string()
            )
        );
    }
}

#[cfg(test)]
mod sum_tests {
    use super::sum;
    use crate::expr::Value;

    #[test]
    fn adds_ordinary_ints() {
        assert_eq!(sum(&Value::Int(2), &Value::Int(3)).unwrap(), Value::Int(5));
    }

    #[test]
    fn mixed_int_float_promotes_to_float_like_ruby_coercion() {
        assert_eq!(
            sum(&Value::Int(2), &Value::Float(3.5)).unwrap(),
            Value::Float(5.5)
        );
    }

    // Ruby's `Integer#+` promotes to Bignum and never overflows; this kernel has no bignum, so
    // overflow refuses instead of panicking or wrapping.
    #[test]
    fn refuses_cleanly_on_overflow_instead_of_panicking_or_wrapping() {
        let result = sum(&Value::Int(i64::MAX), &Value::Int(1));
        assert!(
            result.is_err(),
            "i64::MAX + 1 must refuse, not silently wrap to i64::MIN"
        );
    }

    #[test]
    fn refuses_cleanly_on_negative_overflow() {
        let result = sum(&Value::Int(i64::MIN), &Value::Int(-1));
        assert!(
            result.is_err(),
            "i64::MIN + -1 must refuse, not silently wrap to i64::MAX"
        );
    }

    #[test]
    fn does_not_refuse_right_at_the_boundary() {
        assert_eq!(
            sum(&Value::Int(i64::MAX - 1), &Value::Int(1)).unwrap(),
            Value::Int(i64::MAX)
        );
    }
}

// Ruby's `Integer#+` promotes to Bignum; an `i64` cannot, so `checked_add` refuses on overflow
// instead of panicking (debug) or wrapping (release). Shared with `enumeration.rs`, whose
// `.sum { }` adds its terms one at a time exactly as `+` does.
pub fn sum(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return l.checked_add(*r).map(Value::Int).ok_or_else(|| {
            eval_error(format!(
                "addition overflowed: {l} + {r} does not fit in a 64-bit integer"
            ))
        });
    }
    let l = require_number(lhs, "addition")?;
    let r = require_number(rhs, "addition")?;
    let sum = l + r;
    // C3.4 — a non-finite Float sum faults like an Integer overflow.
    if !sum.is_finite() {
        return Err(eval_error(format!(
            "addition overflowed: {} + {} is not a finite number",
            quoted(lhs),
            quoted(rhs)
        )));
    }
    Ok(Value::Float(sum))
}

/// Shared with `sign_test.rs` — see this file's own header.
pub fn require_number(v: &Value, operation: &str) -> Result<f64, Refusal> {
    scalar::numeric(v).ok_or_else(|| {
        eval_error(format!(
            "{operation} expects a number, got {}",
            rendering::describe(v)
        ))
    })
}

#[cfg(test)]
mod path_operand_tests {
    use crate::expr::{interpret, EvalContext, Expr, Field, Fielded, NoFields, Value};

    // Shaped like a generated multi-field value object: `Charge { cents, currency }`.
    struct Charge(i64);
    impl Fielded for Charge {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match name {
                "cents" => Some(Field::Value(Value::Int(self.0))),
                "currency" => Some(Field::Value(Value::Str("USD".to_string()))),
                _ => None,
            }
        }
    }

    struct Record(Charge);
    impl Fielded for Record {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            (name == "charged").then_some(Field::Nested(&self.0))
        }
    }

    fn percent_of(path: &'static str) -> Value {
        let times = Expr::Mul(Box::new(Expr::Lookup(path)), Box::new(Expr::Int(50)));
        let expr = Expr::Div(Box::new(times), Box::new(Expr::Int(100)));
        interpret(
            &expr,
            &EvalContext {
                args: &NoFields,
                instance: &Record(Charge(10801)),
            },
        )
        .expect("evaluates")
    }

    #[test]
    fn an_operand_reads_a_field_inside_a_value_object_by_path() {
        assert_eq!(percent_of("charged.cents"), Value::Int(5400));
    }
}
