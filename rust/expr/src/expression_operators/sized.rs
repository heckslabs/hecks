//! Interprets `.empty?` and `.size` over strings, lists and arrays.

use crate::attribute_shapes::{list, scalar};
use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::rendering;
use crate::Refusal;

pub fn empty(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Empty(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "sized::empty called with a non-empty? node {expr:?} — a router bug"
        )));
    };

    let v = eval(receiver, ctx)?;
    // Every `Value` variant is named so a new one forces a decision here.
    match v {
        Value::Str(_) => Ok(Value::Bool(scalar::is_empty(&v).ok_or_else(|| {
            eval_error("router bug: Str always answers is_empty".to_string())
        })?)),
        Value::List(_) => Ok(Value::Bool(list::is_empty(&v).ok_or_else(|| {
            eval_error("router bug: List always answers is_empty".to_string())
        })?)),
        // A materialised Array answers from its own length.
        Value::Array(ref elements) => Ok(Value::Bool(elements.is_empty())),
        Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil | Value::Object(_) => {
            Err(eval_error(format!(
                "empty? expects a list or string, got {}",
                rendering::describe(&v)
            )))
        }
    }
}

pub fn size(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Size(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!(
            "sized::size called with a non-size node {expr:?} — a router bug"
        )));
    };

    let v = eval(receiver, ctx)?;
    match v {
        Value::Str(_) => Ok(Value::Int(scalar::size(&v).ok_or_else(|| {
            eval_error("router bug: Str always answers size".to_string())
        })?)),
        Value::List(_) => Ok(Value::Int(list::size(&v).ok_or_else(|| {
            eval_error("router bug: List always answers size".to_string())
        })?)),
        Value::Array(ref elements) => Ok(Value::Int(elements.len() as i64)),
        Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil | Value::Object(_) => {
            Err(eval_error(format!(
                "size expects a list or string, got {}",
                rendering::describe(&v)
            )))
        }
    }
}
