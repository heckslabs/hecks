//! The "text" expression-operator category: `.split`, `.strip` (and `.lstrip`/`.rstrip`),
//! `.start_with?`, `.end_with?`. String receivers only; `expr.rs` routes only these nodes here.

use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::rendering;
use crate::Refusal;

/// Evaluates `.split`, `.strip`, `.start_with?` and `.end_with?`.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    match expr {
        Expr::Split {
            receiver,
            separator,
        } => {
            let text = require_str(&eval(receiver, ctx)?, "split")?;
            Ok(Value::Array(split(&text, separator)))
        }
        Expr::Strip { receiver, side } => {
            let text = require_str(&eval(receiver, ctx)?, "strip")?;
            Ok(Value::Str(side.trim(&text)))
        }
        Expr::StartsWith {
            receiver,
            substring,
        } => {
            let text = require_str(&eval(receiver, ctx)?, "start_with?")?;
            Ok(Value::Bool(text.starts_with(substring.as_str())))
        }
        Expr::EndsWith {
            receiver,
            substring,
        } => {
            let text = require_str(&eval(receiver, ctx)?, "end_with?")?;
            Ok(Value::Bool(text.ends_with(substring.as_str())))
        }
        _ => Err(Refusal::TypeMismatch(format!(
            "text::interpret called with a non-text node {expr:?} — a router bug"
        ))),
    }
}

/// Ruby's `String#split` with a string separator: `" "` splits on runs of whitespace, `""` on
/// characters, anything else on the literal text; trailing empty fields are dropped.
fn split(text: &str, separator: &str) -> Vec<Value> {
    let mut parts: Vec<String> = match separator {
        " " => text
            .split([' ', '\t', '\n', '\u{0b}', '\u{0c}', '\r'])
            .filter(|p| !p.is_empty())
            .map(str::to_string)
            .collect(),
        "" => text.chars().map(String::from).collect(),
        sep => text.split(sep).map(str::to_string).collect(),
    };
    while parts.last().is_some_and(String::is_empty) {
        parts.pop();
    }
    parts.into_iter().map(Value::Str).collect()
}

fn require_str(v: &Value, op: &str) -> Result<String, Refusal> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        other => Err(eval_error(format!(
            "{op} expects a string, got {}",
            rendering::describe(other)
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::expr::NoFields;

    fn run(expr: &Expr) -> Value {
        let ctx = EvalContext {
            args: &NoFields,
            instance: &NoFields,
        };
        eval(expr, &ctx).expect("evaluates")
    }

    fn str(s: &str) -> Expr {
        Expr::Str(s.to_string())
    }

    #[test]
    fn split_matches_rubys_trailing_empty_trim() {
        let phrase = Expr::Split {
            receiver: Box::new(str("a::b::c::")),
            separator: "::".to_string(),
        };
        assert_eq!(
            run(&phrase),
            Value::Array(vec![
                Value::Str("a".to_string()),
                Value::Str("b".to_string()),
                Value::Str("c".to_string())
            ])
        );
    }

    #[test]
    fn split_on_a_missing_separator_returns_the_whole_string_as_one_element() {
        let phrase = Expr::Split {
            receiver: Box::new(str("abc")),
            separator: "::".to_string(),
        };
        assert_eq!(
            run(&phrase),
            Value::Array(vec![Value::Str("abc".to_string())])
        );
    }

    #[test]
    fn strip_trims_rubys_whitespace_set_and_nothing_else() {
        use crate::expr::StripSide;
        let strip = |side, text: &str| {
            run(&Expr::Strip {
                receiver: Box::new(str(text)),
                side,
            })
        };
        assert_eq!(
            strip(StripSide::Both, " \t\n a b \r\u{b}\u{c}\0"),
            Value::Str("a b".to_string())
        );
        assert_eq!(
            strip(StripSide::Left, "\0  a "),
            Value::Str("a ".to_string())
        );
        assert_eq!(
            strip(StripSide::Right, " a \0 "),
            Value::Str(" a".to_string())
        );
        assert_eq!(strip(StripSide::Both, "   "), Value::Str(String::new()));
        // A non-breaking space is not Ruby whitespace, so it stays.
        assert_eq!(
            strip(StripSide::Both, "\u{a0}a\u{a0}"),
            Value::Str("\u{a0}a\u{a0}".to_string())
        );
    }

    #[test]
    fn strip_on_a_non_string_refuses_with_the_operator_named() {
        use crate::expr::StripSide;
        let ctx = EvalContext {
            args: &NoFields,
            instance: &NoFields,
        };
        let err = eval(
            &Expr::Strip {
                receiver: Box::new(Expr::Int(1)),
                side: StripSide::Both,
            },
            &ctx,
        )
        .unwrap_err();
        assert!(
            format!("{err:?}").contains("strip expects a string"),
            "{err:?}"
        );
    }

    #[test]
    fn start_and_end_with() {
        assert_eq!(
            run(&Expr::StartsWith {
                receiver: Box::new(str("{}")),
                substring: "{".to_string()
            }),
            Value::Bool(true)
        );
        assert_eq!(
            run(&Expr::EndsWith {
                receiver: Box::new(str("{}")),
                substring: "}".to_string()
            }),
            Value::Bool(true)
        );
        assert_eq!(
            run(&Expr::StartsWith {
                receiver: Box::new(str("[]")),
                substring: "{".to_string()
            }),
            Value::Bool(false)
        );
    }

    #[test]
    fn a_non_string_receiver_refuses_with_the_operator_named() {
        let ctx = EvalContext {
            args: &NoFields,
            instance: &NoFields,
        };
        let err = eval(
            &Expr::StartsWith {
                receiver: Box::new(Expr::Int(1)),
                substring: "x".to_string(),
            },
            &ctx,
        )
        .unwrap_err();
        assert!(
            format!("{err:?}").contains("start_with? expects a string"),
            "{err:?}"
        );
    }
}
