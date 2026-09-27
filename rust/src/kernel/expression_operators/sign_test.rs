//! Interprets `.positive?`, `.negative?` and `.zero?` as comparisons of the receiver with 0.

use crate::kernel::expr::{interpret as eval, EvalContext, Expr, Value};
use crate::kernel::expression_operators::{arithmetic::require_number, comparison};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::SignTest { op, receiver } = expr else {
        return Err(Refusal::TypeMismatch(format!("sign_test::interpret called with a non-sign-test node {expr:?} — a router bug")));
    };

    // Comparing against 0 through `comparison::apply` treats int and float alike.
    let v = eval(receiver, ctx)?;
    require_number(&v, "sign test")?;
    Ok(Value::Bool(comparison::apply(op, &v, &Value::Int(0))?))
}
