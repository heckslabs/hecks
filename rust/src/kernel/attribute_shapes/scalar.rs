// The `:scalar` shape of `Runtime::Value::Coercion::SHAPES`: `Value::{Str,Int,Float,Bool}`.
// `List` and `Nil` belong to the other shapes, so every function here returns `None` for them.

use crate::kernel::expr::Value;

// Mirrors `Resolver.numeric`: `Int` and `Float` mix freely; any other `Value` is not a number.
pub fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Int(i) => Some(*i as f64),
        Value::Float(f) => Some(*f),
        _ => None,
    }
}

// `.to_s` on a scalar; `None` for `List`/`Nil`.
pub fn to_s(v: &Value) -> Option<Value> {
    match v {
        Value::Str(s) => Some(Value::Str(s.clone())),
        Value::Int(i) => Some(Value::Str(i.to_string())),
        Value::Float(f) => Some(Value::Str(f.to_string())),
        Value::Bool(b) => Some(Value::Str(b.to_string())),
        Value::List(_) | Value::Nil | Value::Array(_) => None,
    }
}

// Only `Str` has a length; `Int`/`Float`/`Bool` answer `None` so the caller refuses.
pub fn is_empty(v: &Value) -> Option<bool> {
    match v {
        Value::Str(s) => Some(s.is_empty()),
        _ => None,
    }
}

pub fn size(v: &Value) -> Option<i64> {
    match v {
        Value::Str(s) => Some(s.chars().count() as i64),
        _ => None,
    }
}
