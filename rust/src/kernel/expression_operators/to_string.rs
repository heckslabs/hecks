// Implements the Ruby grammar's "to_string" expression-operator category
// (projection.json: `.to_s`, its one member) — `Resolver::ToS`
// (resolver.rb), read directly.
//
// EVERY `Value` VARIANT IS NAMED BELOW, NONE LEFT TO A WILDCARD — see
// `sized.rs`'s own header for why. Unlike `.empty?`/`.size`, most
// `Value` shapes convert to a string in Ruby (`nil.to_s == ""`,
// `3.to_s == "3"`, ...) — `Str`/`Int`/`Float`/`Bool` (the "scalar"
// attribute shape) and `Nil` (the "optional" shape, absent-or-literal)
// each get an explicit arm, routed to the file that owns that shape's
// own `.to_s` rule, rather than reimplemented here. `List`/`Array` are
// the exception: no real corpus predicate ever calls `.to_s` on a
// list-typed field or a materialised array, and Ruby's own `Array#to_s`
// (`.inspect`-shaped) isn't ported here, so that arm still refuses,
// explicitly, rather than silently stringifying a length or a joined
// list nobody asked for.
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `ToS` — see `logical.rs`'s header for why the trailing arm
// is a router-bug guard, not a real refusal path.

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
