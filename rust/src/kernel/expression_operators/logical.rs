// Implements the Ruby grammar's "logical" expression-operator category
// (lib/hecks/bluebook/expression/projection.json: `||`, `&&`, `!`)
// — `Bluebook::Expression::Evaluator`'s `Or`/`And`/`Not` node
// interpretation (evaluator.rb), read directly: Rust's own `||`/`&&`
// already short-circuit the identical way Ruby's do (the right side is
// never interpreted once the left side alone decides the result), so
// there is nothing to hand-roll beyond calling back into `interpret` for
// each side; `!` inverts truthiness.
//
// `expr.rs`'s `category_of` is what guarantees this is only ever called
// with `Or`/`And`/`Not` — the trailing arm below is what "the router
// called the wrong file" looks like if that guarantee is ever broken,
// the same idiom `dispatch.rs`'s own lifecycle-field-mismatch arm
// already uses for the identical class of "not a real refusal, a
// codegen/router bug" situation.

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
