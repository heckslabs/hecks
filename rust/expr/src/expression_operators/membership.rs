//! Interprets `.include?` over a String or Array haystack.
//! Array haystacks come from computed lists (`.split`); literal arrays are rewritten at codegen.

use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::rendering;
use crate::Refusal;

/// Evaluates `.include?` over a list or a string.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Include { haystack, needle } = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "membership::interpret called with a non-membership node {expr:?} — a router bug"
        )));
    };

    let wanted = eval(needle, ctx)?;
    match eval(haystack, ctx)? {
        // Numeric-coerced equality, matching `Evaluator#includes?`.
        Value::Array(items) => {
            Ok(Value::Bool(items.iter().any(|item| {
                super::comparison::values_equal(item, &wanted)
            })))
        }
        Value::Str(text) => match &wanted {
            Value::Str(part) => Ok(Value::Bool(text.contains(part.as_str()))),
            other => Err(eval_error(format!(
                "no implicit conversion of {} into String",
                rendering::class_of(other)
            ))),
        },
        _ => Ok(Value::Bool(false)),
    }
}
