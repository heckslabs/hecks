// Implements the Ruby grammar's "presence" expression-operator category
// (projection.json: `.present?`, `.blank?` — two symbols, one interpreter
// node sharing a `negated` flag, the exact `SignTest`-style precedent
// `sign_test.rs`'s own header already documents for a symbol pair sugar
// over one primitive) — `Resolver::Presence` (resolver.rb's `blank?`),
// read directly: Rails-standard semantics, not just `!nil?` — `nil`/
// `false` are blank, and a `Str`/`List`/`Array` is blank when EMPTY, not
// merely falsy.
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `Presence` — see `logical.rs`'s header for why the
// trailing arm is a router-bug guard, not a real refusal path.

use crate::kernel::expr::{interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Presence { receiver, negated } = expr else {
        return Err(Refusal::TypeMismatch(format!("presence::interpret called with a non-presence node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    let present = !blank(&v);
    Ok(Value::Bool(if *negated { !present } else { present }))
}

/// `Resolver#blank?`, read directly: `nil`/`false` are blank outright;
/// `Str`/`Array` (this kernel's ArrayLiteral/Split-produced list, the
/// same reading Ruby's own `Array#empty?` gives a real Array) are blank
/// when EMPTY; every other `Value` (`Int`/`Float`/`Bool(true)`/`List`,
/// a field-list's own bare length) is never blank — a `Value` with no
/// meaningful "empty" reading is present by definition, the identical
/// `else false` Ruby's own `case` falls through to.
fn blank(v: &Value) -> bool {
    match v {
        Value::Nil | Value::Bool(false) => true,
        Value::Str(s) => s.is_empty(),
        Value::Array(elements) => elements.is_empty(),
        Value::Int(_) | Value::Float(_) | Value::Bool(true) | Value::List(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::NoFields;

    fn present(receiver: Expr, negated: bool) -> Value {
        let expr = Expr::Presence { receiver: Box::new(receiver), negated };
        let ctx = EvalContext { args: &NoFields, instance: &NoFields };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn nil_and_false_are_blank() {
        assert_eq!(present(Expr::Nil, false), Value::Bool(false));
        assert_eq!(present(Expr::Bool(false), false), Value::Bool(false));
    }

    #[test]
    fn an_empty_string_is_blank_but_a_nonempty_one_is_present() {
        assert_eq!(present(Expr::Str(String::new()), false), Value::Bool(false));
        assert_eq!(present(Expr::Str("x".to_string()), false), Value::Bool(true));
    }

    #[test]
    fn zero_and_false_scalar_are_present_not_blank() {
        assert_eq!(present(Expr::Int(0), false), Value::Bool(true));
    }

    #[test]
    fn blank_negates_present() {
        assert_eq!(present(Expr::Nil, true), Value::Bool(true));
        assert_eq!(present(Expr::Str("x".to_string()), true), Value::Bool(false));
    }

    #[test]
    fn an_empty_array_literal_is_blank() {
        assert_eq!(present(Expr::Array(vec![]), false), Value::Bool(false));
        assert_eq!(present(Expr::Array(vec![Expr::Int(1)]), false), Value::Bool(true));
    }
}
