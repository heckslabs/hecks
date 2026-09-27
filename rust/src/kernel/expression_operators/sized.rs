//! Interprets `.empty?` and `.size` over strings, lists and arrays.

use crate::kernel::attribute_shapes::{list, scalar};
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn empty(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Empty(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!("sized::empty called with a non-empty? node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    // Every `Value` variant is named so a new one forces a decision here.
    match v {
        Value::Str(_) => Ok(Value::Bool(scalar::is_empty(&v).expect("Str always answers is_empty"))),
        Value::List(_) => Ok(Value::Bool(list::is_empty(&v).expect("List always answers is_empty"))),
        // A materialised Array answers from its own length.
        Value::Array(ref elements) => Ok(Value::Bool(elements.is_empty())),
        Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil => Err(eval_error(format!("empty? expects a list or string, got {v:?}"))),
    }
}

pub fn size(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Size(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!("sized::size called with a non-size node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    match v {
        Value::Str(_) => Ok(Value::Int(scalar::size(&v).expect("Str always answers size"))),
        Value::List(_) => Ok(Value::Int(list::size(&v).expect("List always answers size"))),
        Value::Array(ref elements) => Ok(Value::Int(elements.len() as i64)),
        Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil => Err(eval_error(format!("size expects a list or string, got {v:?}"))),
    }
}
