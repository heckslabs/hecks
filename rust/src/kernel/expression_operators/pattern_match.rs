//! Interprets `.match?` against a Ruby-style pattern with `i`/`m`/`x` flags.
//! `regex` is the kernel's one dependency: a hand-rolled subset cannot reach Ruby parity.

use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;
use regex::RegexBuilder;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::MatchesRegex { receiver, pattern, flags } = expr else {
        return Err(Refusal::TypeMismatch(format!("pattern_match::interpret called with a non-match? node {expr:?} — a router bug")));
    };

    let text = coerce_text(&eval(receiver, ctx)?)?;

    // Ruby's `/x` is `ignore_whitespace` in `regex`; `i` and `m` map directly.
    let mut builder = RegexBuilder::new(pattern);
    builder.case_insensitive(flags.contains('i'));
    builder.multi_line(flags.contains('m'));
    builder.ignore_whitespace(flags.contains('x'));

    let re = builder
        .build()
        .map_err(|e| eval_error(format!("match? given an invalid pattern {pattern:?} — {e}")))?;

    Ok(Value::Bool(re.is_match(&text)))
}

/// Text form of a scalar receiver: nil is empty, Bool and lists refuse.
fn coerce_text(v: &Value) -> Result<String, Refusal> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        Value::Int(i) => Ok(i.to_string()),
        Value::Float(f) => Ok(f.to_string()),
        Value::Nil => Ok(String::new()),
        Value::Bool(_) | Value::List(_) | Value::Array(_) => Err(eval_error(format!("match? expects a scalar, got {v:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(receiver: Expr, pattern: &str, flags: &str) -> Value {
        let expr = Expr::MatchesRegex { receiver: Box::new(receiver), pattern: pattern.to_string(), flags: flags.to_string() };
        let ctx = EvalContext { args: &crate::kernel::expr::NoFields, instance: &crate::kernel::expr::NoFields };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn matches_a_simple_anchored_pattern() {
        assert_eq!(matches(Expr::Str("12345".to_string()), r"\A\d{5}\z", ""), Value::Bool(true));
        assert_eq!(matches(Expr::Str("1234".to_string()), r"\A\d{5}\z", ""), Value::Bool(false));
    }

    #[test]
    fn the_i_flag_ignores_case() {
        assert_eq!(matches(Expr::Str("HELLO".to_string()), "hello", ""), Value::Bool(false));
        assert_eq!(matches(Expr::Str("HELLO".to_string()), "hello", "i"), Value::Bool(true));
    }

    #[test]
    fn coerces_non_string_scalars_to_text() {
        assert_eq!(matches(Expr::Int(12345), r"\A\d+\z", ""), Value::Bool(true));
        assert_eq!(matches(Expr::Nil, r"\A\z", ""), Value::Bool(true));
    }

    #[test]
    fn an_invalid_pattern_refuses_cleanly() {
        let expr = Expr::MatchesRegex { receiver: Box::new(Expr::Str("x".to_string())), pattern: "(".to_string(), flags: String::new() };
        let ctx = EvalContext { args: &crate::kernel::expr::NoFields, instance: &crate::kernel::expr::NoFields };
        assert!(eval(&expr, &ctx).is_err());
    }
}
