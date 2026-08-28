// Implements the Ruby grammar's "membership" expression-operator category
// (projection.json: `.include?`, its one member) — `Evaluator::Include`'s
// interpretation (evaluator.rb's `includes?`), read directly.
//
// Real corpus `given`/`ensures`/invariant text only ever calls `.include?`
// with a String haystack directly, OR a literal-array haystack
// (`["issued", "active"].include?(status)`) — `rust/project/
// expr_emitter.rb`'s own `emit_include` rewrites the LATTER into an
// OR-of-equalities at codegen time (see its header), so it never reaches
// this file as a `Value::Array` at all. A `Value::Array` DOES reach here
// for real, though, the moment a haystack is COMPUTED rather than
// written literally — `x.split("::").include?("a")` composes `Split`
// (`expression_operators::text`) with `.include?` exactly this way, and
// unlike the literal case there is no fixed set of elements at codegen
// time to rewrite into equalities, so this is where that composition
// actually needs to work. `INCLUDE_HAYSTACKS` (evaluator.rb) admits
// Array on the Ruby side for the identical reason.
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
        // `Evaluator#includes?`'s own `Array` branch: `found.any? { |item| equal?(item, wanted) }`
        // — numeric-coerced equality, the same primitive `comparison::apply`'s
        // own `values_equal` already provides, reused rather than re-derived.
        (Value::Array(h), n) => Ok(Value::Bool(h.iter().any(|item| super::comparison::values_equal(item, &n)))),
        (h, n) => Err(eval_error(format!("include? on {h:?} with {n:?} — a real (non-literal, non-split) Array haystack is not generated yet"))),
    }
}
