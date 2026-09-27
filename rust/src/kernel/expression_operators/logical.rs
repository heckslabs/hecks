//! `||`, `&&` and `!` (`Evaluator`'s `Or`/`And`/`Not`); the right side short-circuits as in Ruby.

use crate::kernel::expr::{interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    match expr {
        Expr::Or(l, r) => Ok(Value::Bool(eval(l, ctx)?.truthy() || eval(r, ctx)?.truthy())),
        Expr::And(l, r) => Ok(Value::Bool(eval(l, ctx)?.truthy() && eval(r, ctx)?.truthy())),
        Expr::Not(n) => Ok(Value::Bool(!eval(n, ctx)?.truthy())),
        _ => Err(Refusal::TypeMismatch(format!("logical::interpret called with a non-logical node {expr:?} — a router bug"))),
    }
}
