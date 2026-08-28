// Implements the Ruby grammar's "text" expression-operator category
// (projection.json: `.split`, `.start_with?`, `.end_with?` — three
// symbols, three interpreter nodes sharing one category, the same
// `sized.rs`-style grouping precedent: different node shapes, one
// category, because all three ask a question of a STRING specifically)
// — `Resolver::Split`/`::StartsWith`/`::EndsWith` (resolver.rb's
// `split_value`/`starts_with?`/`ends_with?`), read directly. String-only,
// same reasoning the Ruby resolver's own comments give: every corpus
// usage found splits or checks the ends of a real String field, never a
// coerced non-string.
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `Split`/`StartsWith`/`EndsWith` — see `logical.rs`'s
// header for why the trailing arm is a router-bug guard, not a real
// refusal path.

use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    match expr {
        Expr::Split { receiver, separator } => {
            let text = require_str(&eval(receiver, ctx)?, "split")?;
            // Ruby's `String#split(sep)` with a non-empty literal
            // separator never returns a trailing empty element the way
            // a raw byte-split naively would for `"a::".split("::")`
            // (`["a", ""]` in a naive split vs. Ruby's own `["a"]`) —
            // `Vec<&str>::split` matches Rust's own semantics, not
            // Ruby's, for that trailing-empty case, so trailing empties
            // are trimmed the same way Ruby's own `split` (limit
            // defaulted, not `-1`) already does.
            let mut parts: Vec<&str> = text.split(separator.as_str()).collect();
            while parts.last() == Some(&"") {
                parts.pop();
            }
            Ok(Value::Array(parts.into_iter().map(|p| Value::Str(p.to_string())).collect()))
        }
        Expr::StartsWith { receiver, substring } => {
            let text = require_str(&eval(receiver, ctx)?, "start_with?")?;
            Ok(Value::Bool(text.starts_with(substring.as_str())))
        }
        Expr::EndsWith { receiver, substring } => {
            let text = require_str(&eval(receiver, ctx)?, "end_with?")?;
            Ok(Value::Bool(text.ends_with(substring.as_str())))
        }
        _ => Err(Refusal::TypeMismatch(format!("text::interpret called with a non-text node {expr:?} — a router bug"))),
    }
}

fn require_str(v: &Value, op: &str) -> Result<String, Refusal> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        other => Err(eval_error(format!("{op} expects a string, got {other:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::NoFields;

    fn run(expr: Expr) -> Value {
        let ctx = EvalContext { args: &NoFields, instance: &NoFields };
        eval(&expr, &ctx).expect("evaluates")
    }

    fn str(s: &str) -> Expr {
        Expr::Str(s.to_string())
    }

    #[test]
    fn split_matches_rubys_trailing_empty_trim() {
        let phrase = Expr::Split { receiver: Box::new(str("a::b::c::")), separator: "::".to_string() };
        assert_eq!(
            run(phrase),
            Value::Array(vec![Value::Str("a".to_string()), Value::Str("b".to_string()), Value::Str("c".to_string())])
        );
    }

    #[test]
    fn split_on_a_missing_separator_returns_the_whole_string_as_one_element() {
        let phrase = Expr::Split { receiver: Box::new(str("abc")), separator: "::".to_string() };
        assert_eq!(run(phrase), Value::Array(vec![Value::Str("abc".to_string())]));
    }

    #[test]
    fn start_and_end_with() {
        assert_eq!(run(Expr::StartsWith { receiver: Box::new(str("{}")), substring: "{".to_string() }), Value::Bool(true));
        assert_eq!(run(Expr::EndsWith { receiver: Box::new(str("{}")), substring: "}".to_string() }), Value::Bool(true));
        assert_eq!(run(Expr::StartsWith { receiver: Box::new(str("[]")), substring: "{".to_string() }), Value::Bool(false));
    }

    #[test]
    fn a_non_string_receiver_refuses_with_the_operator_named() {
        let ctx = EvalContext { args: &NoFields, instance: &NoFields };
        let err = eval(&Expr::StartsWith { receiver: Box::new(Expr::Int(1)), substring: "x".to_string() }, &ctx).unwrap_err();
        assert!(format!("{err:?}").contains("start_with? expects a string"), "{err:?}");
    }
}
