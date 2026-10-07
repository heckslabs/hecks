//! Interprets `.present?`/`.blank?` and `.set?`/`.unset?`.
//! The two pairs share one operator category and differ in how they treat empty values.

use crate::kernel::expr::{interpret as eval, lookup_field, EvalContext, Expr, Field, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Presence { receiver, negated } = expr else {
        return Err(Refusal::TypeMismatch(format!("presence::interpret called with a non-presence node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    let present = !blank(&v);
    Ok(Value::Bool(if *negated { !present } else { present }))
}

/// `.set?` / `.unset?`: only nil is unset, so an empty Str or Array is set (unlike `.present?`).
pub fn interpret_assignment(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Assignment { receiver, negated } = expr else {
        return Err(Refusal::TypeMismatch(format!("presence::interpret_assignment called with a non-assignment node {expr:?} — a router bug")));
    };

    let set = match &**receiver {
        // A nested object (an optional value-object attribute) is set whenever it is present.
        Expr::Lookup(path) => match lookup_field(path, ctx)? {
            Field::Nested(_) => true,
            Field::Value(v) => !matches!(v, Value::Nil),
        },
        other => !matches!(eval(other, ctx)?, Value::Nil),
    };
    Ok(Value::Bool(if *negated { !set } else { set }))
}

/// Rails-style blankness: nil, false, and an empty Str or Array.
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

    // A record with one value-object field (`body`, holding a nested object or nothing).
    struct Draft {
        body: Option<Body>,
    }
    struct Body;
    impl crate::kernel::expr::Fielded for Body {
        fn field(&self, _name: &str) -> Option<Field<'_>> {
            None
        }
    }
    impl crate::kernel::expr::Fielded for Draft {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match (name, &self.body) {
                ("body", Some(body)) => Some(Field::Nested(body)),
                ("body", None) => Some(Field::Value(Value::Nil)),
                _ => None,
            }
        }
    }

    fn set_on(draft: &Draft, negated: bool) -> Value {
        let expr = Expr::Assignment { receiver: Box::new(Expr::Lookup("body")), negated };
        eval(&expr, &EvalContext { args: &NoFields, instance: draft }).expect("evaluates")
    }

    #[test]
    fn a_nested_object_field_is_set_and_an_absent_one_is_not() {
        assert_eq!(set_on(&Draft { body: Some(Body) }, false), Value::Bool(true));
        assert_eq!(set_on(&Draft { body: None }, false), Value::Bool(false));
        assert_eq!(set_on(&Draft { body: Some(Body) }, true), Value::Bool(false));
    }

    #[test]
    fn unset_negates_set() {
        assert_eq!(set(Expr::Nil, true), Value::Bool(true));
        assert_eq!(set(Expr::Str("x".to_string()), true), Value::Bool(false));
    }
}
