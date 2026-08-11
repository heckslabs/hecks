// Implements the Ruby grammar's "sized" expression-operator category
// (projection.json: `.empty?`, `.size` — two symbols, two interpreter
// nodes sharing one category) — `Resolver::Empty`/`Resolver::Size`
// (resolver.rb), read directly: both ask a question about a value's own
// LENGTH, differing only in whether the answer is a boolean or a count.
// Routed straight through the two attribute shapes that HAVE a length —
// `attribute_shapes::scalar` (a `Str` value's own character count) and
// `attribute_shapes::list` (a list field's already-bare length) — rather
// than reimplemented here; this file's own job is only "which shape
// answered, and what to say when none did."
//
// EVERY `Value` VARIANT IS NAMED BELOW, NONE LEFT TO A WILDCARD. The
// four that don't support `.empty?`/`.size` (`Int`, `Float`, `Bool`,
// `Nil`) are refused explicitly, one arm each, rather than behind a
// catch-all `_ =>` — the same reasoning `expr.rs`'s own header gives for
// `dispatch_operator`'s enum match: if `Value` ever grows a SEVENTH
// variant (a new attribute-representation shape at the `Value` level,
// not merely a new `AttributeShape`/`OperatorCategory` name), a wildcard
// here would silently decide "refuse it" for a case nobody actually
// evaluated — an explicit arm forces whoever adds the variant to decide
// on purpose whether `.empty?`/`.size` support it.
//
// `expr.rs`'s `category_of` guarantees `empty`/`size` below are only
// ever called with `Empty`/`Size` respectively — see `logical.rs`'s
// header for why each trailing arm is a router-bug guard, not a real
// refusal path.

use crate::kernel::attribute_shapes::{list, scalar};
use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn empty(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Empty(receiver) = expr else {
        return Err(Refusal::TypeMismatch(format!("sized::empty called with a non-empty? node {expr:?} — a router bug")));
    };

    let v = eval(receiver, ctx)?;
    match v {
        Value::Str(_) => Ok(Value::Bool(scalar::is_empty(&v).expect("Str always answers is_empty"))),
        Value::List(_) => Ok(Value::Bool(list::is_empty(&v).expect("List always answers is_empty"))),
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
        Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil => Err(eval_error(format!("size expects a list or string, got {v:?}"))),
    }
}
