// Implements the Ruby grammar's "membership" expression-operator category
// (projection.json: `.include?`, its one member) — `Evaluator::Include`'s
// interpretation (evaluator.rb's `includes?`), read directly.
//
// Real corpus `given`/`ensures`/invariant text only ever calls `.include?`
// with a String haystack — `INCLUDE_HAYSTACKS` (evaluator.rb) also admits
// Array on the Ruby side, but no example domain's canonical text exercises
// it, so it isn't generated here yet (flagged, not silently assumed away
// — see the error text below, which names the gap instead of hiding it).
//
// `expr.rs`'s `category_of` guarantees this is only ever called with
// `Include` — see `logical.rs`'s header for why the trailing arm below
// is a router-bug guard, not a real refusal path.

use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::Include { haystack, needle } = expr else {
        return Err(Refusal::TypeMismatch(format!("membership::interpret called with a non-membership node {expr:?} — a router bug")));
    };

    match (eval(haystack, ctx)?, eval(needle, ctx)?) {
        (Value::Str(h), Value::Str(n)) => Ok(Value::Bool(h.contains(&n))),
        (h, n) => Err(eval_error(format!("include? on {h:?} with {n:?} — Array haystacks not generated yet"))),
    }
}
