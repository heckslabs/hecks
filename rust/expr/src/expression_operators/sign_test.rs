//! Interprets `.positive?`, `.negative?` and `.zero?` as comparisons of the receiver with 0.

use crate::expr::{interpret as eval, EvalContext, Expr, Value};
use crate::expression_operators::{arithmetic::require_number, comparison};
use crate::Refusal;

/// Evaluates `.positive?`, `.negative?` and `.zero?`.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::SignTest { op, receiver } = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "sign_test::interpret called with a non-sign-test node {expr:?} — a router bug"
        )));
    };

    // Comparing against 0 through `comparison::apply` treats int and float alike.
    let v = eval(receiver, ctx)?;
    require_number(&v, sign_test_name(*op))?;
    Ok(Value::Bool(comparison::apply(op, &v, &Value::Int(0))?))
}

/// The Ruby predicate a sign test stands for, which an error names.
const fn sign_test_name(cmp: comparison::Comparison) -> &'static str {
    match (cmp.less_than, cmp.equal) {
        (true, true) => "positive?",
        (true, false) => "negative?",
        _ => "zero?",
    }
}
