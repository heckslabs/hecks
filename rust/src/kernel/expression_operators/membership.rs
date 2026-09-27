//! Interprets `.include?` over a String or Array haystack.
//! Array haystacks come from computed lists (`.split`); literal arrays are rewritten at codegen.

use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Include { haystack, needle } = expr else {
        return Err(Refusal::TypeMismatch(format!("membership::interpret called with a non-membership node {expr:?} — a router bug")));
    };

    match (eval(haystack, ctx)?, eval(needle, ctx)?) {
        (Value::Str(h), Value::Str(n)) => Ok(Value::Bool(h.contains(&n))),
        // Numeric-coerced equality, matching `Evaluator#includes?`.
        (Value::Array(h), n) => Ok(Value::Bool(h.iter().any(|item| super::comparison::values_equal(item, &n)))),
        (h, n) => Err(eval_error(format!("include? on {h:?} with {n:?} — a real (non-literal, non-split) Array haystack is not generated yet"))),
    }
}
