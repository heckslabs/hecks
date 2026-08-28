// Implements the Ruby grammar's "presence" expression-operator category
// (projection.json: `.present?`, `.blank?`, `.set?`, `.unset?` — two
// symbol pairs, one interpreter FUNCTION each, sharing a `negated` flag
// the exact `SignTest`-style precedent `sign_test.rs`'s own header
// already documents for a symbol pair sugar over one primitive) —
// `Resolver::Presence` (resolver.rb's `blank?`), read directly:
// Rails-standard semantics, not just `!nil?` — `nil`/`false` are blank,
// and a `Str`/`List`/`Array` is blank when EMPTY, not merely falsy.
//
// `.set?`/`.unset?` (`Resolver::Assignment`, `interpret_assignment`
// below) ask a DELIBERATELY narrower question instead: `!receiver.
// is_nil()`, full stop — an assigned-but-empty `Str`/`Array` is `.set?`,
// unlike `.present?`'s own reading of the identical value. Both symbol
// pairs share this one file because both share `OperatorCategory::
// Presence` (`expr.rs`'s own `category_of`) — the same "one category,
// several `Expr` variants, one function each" shape `arithmetic.rs`
// already uses for `Add`/`Modulo`.
//
// `expr.rs`'s `category_of` maps BOTH `Presence` and `Assignment` to
// `OperatorCategory::Presence`; `dispatch_operator` sub-matches on the
// `Expr` variant itself to pick `interpret` vs `interpret_assignment` —
// see `logical.rs`'s header for why each function's own trailing arm is
// a router-bug guard, not a real refusal path.

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

/// `receiver.set?` / `receiver.unset?` — `Expr::Assignment`, the sibling
/// question to `interpret` above: `!receiver.is_nil()`, full stop. NOT
/// `blank()` — an assigned-but-empty `Str`/`Array` is `.set?`, unlike
/// `Presence`'s own reading of the identical value (`blank()`'s own
/// header has the full contrast). Kept in this file rather than a
/// sibling one: both share `OperatorCategory::Presence` (`expr.rs`'s own
/// `category_of`), the same "one category, several `Expr` variants"
/// precedent `arithmetic.rs`/`sized.rs` already set for `Add`/`Modulo`
/// and `Empty`/`Size`.
pub fn interpret_assignment(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Assignment { receiver, negated } = expr else {
        return Err(Refusal::TypeMismatch(format!("presence::interpret_assignment called with a non-assignment node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    let set = !matches!(v, Value::Nil);
    Ok(Value::Bool(if *negated { !set } else { set }))
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

    fn set(receiver: Expr, negated: bool) -> Value {
        let expr = Expr::Assignment { receiver: Box::new(receiver), negated };
        let ctx = EvalContext { args: &NoFields, instance: &NoFields };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn only_nil_is_unset() {
        assert_eq!(set(Expr::Nil, false), Value::Bool(false));
        assert_eq!(set(Expr::Bool(false), false), Value::Bool(true));
    }

    #[test]
    fn an_empty_string_or_array_is_set_unlike_present_s_own_reading() {
        assert_eq!(set(Expr::Str(String::new()), false), Value::Bool(true));
        assert_eq!(set(Expr::Array(vec![]), false), Value::Bool(true));
    }

    #[test]
    fn unset_negates_set() {
        assert_eq!(set(Expr::Nil, true), Value::Bool(true));
        assert_eq!(set(Expr::Str("x".to_string()), true), Value::Bool(false));
    }
}
