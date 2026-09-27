//! The "to_string" expression-operator category: `.to_s`.
//! Lists and arrays refuse rather than stringify.

use crate::kernel::attribute_shapes::{optional, scalar};
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::ToS(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!("to_string::interpret called with a non-to_s node {expr:?} — a router bug")));
    };

    match eval(receiver, ctx)? {
        v @ (Value::Str(_) | Value::Int(_) | Value::Float(_) | Value::Bool(_)) => Ok(scalar::to_s(&v).expect("scalar shape always stringifies")),
        Value::Nil => Ok(optional::to_s(&Value::Nil).expect("Nil always stringifies to \"\"")),
        v @ (Value::List(_) | Value::Array(_)) => Err(eval_error(format!("to_s expects a scalar, got {v:?}"))),
    }
}
