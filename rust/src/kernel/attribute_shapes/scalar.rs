// Implements the `:scalar` branch of `Runtime::Value::Coercion::SHAPES`
// (lib/hecks/runtime/value/coercion.rb) — `for_attribute`'s final
// `else value` (the value object lookup misses, so the raw
// String/Integer/Float/Boolean value passes through unchanged). At the
// expression-evaluation layer that "raw value" is one of this kernel's
// `Value::{Str,Int,Float,Bool}` — deliberately NOT `Value::List` (the
// `:list` shape, list.rs's own file) or `Value::Nil` (the `:optional`
// shape, optional.rs) — so every function here explicitly excludes those
// two rather than accepting `Value` wholesale and hoping callers only
// ever pass a scalar.

use crate::kernel::expr::Value;

/// Ruby's implicit numeric coercion inside `Evaluator.less_than`/`equal?`
/// — `Resolver.numeric(lhs)` (resolver.rb): `Integer`/`Float` compare and
/// add across each other freely (nothing in the corpus's own arithmetic
/// distinguishes them), every other `Value` — scalar or not — is not a
/// number. Used by `expression_operators::comparison` (comparing) and
/// `expression_operators::arithmetic` (adding/modulo'ing) alike, so it
/// lives here rather than duplicated in both.
pub fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Int(i) => Some(*i as f64),
        Value::Float(f) => Some(*f),
        _ => None,
    }
}

/// `Resolver::ToS`'s scalar half — `.to_s` on a `Str`/`Int`/`Float`/
/// `Bool` value (`expression_operators::to_string` calls this before
/// falling back to `optional::to_s` for the `Nil` case that isn't a
/// scalar at all). `None` for any non-scalar `Value` (`List`/`Nil`),
/// same reasoning as `numeric` above.
pub fn to_s(v: &Value) -> Option<Value> {
    match v {
        Value::Str(s) => Some(Value::Str(s.clone())),
        Value::Int(i) => Some(Value::Str(i.to_string())),
        Value::Float(f) => Some(Value::Str(f.to_string())),
        Value::Bool(b) => Some(Value::Str(b.to_string())),
        Value::List(_) | Value::Nil => None,
    }
}

/// `Resolver::Empty`/`Resolver::Size`'s scalar half — the only scalar
/// `Value` with a length at all is `Str` (`Int`/`Float`/`Bool` have none
/// to ask about, so `None` for those, matched by
/// `expression_operators::sized` falling through to its own explicit
/// refusal arm rather than this file inventing an answer).
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
