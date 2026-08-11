// Implements the Ruby grammar's "sign_test" expression-operator category
// (projection.json: `.positive?`, `.negative?`, `.zero?` — three
// symbols, one interpreter node) — `Resolver::SignTest`
// (resolver.rb's `sign_test_node`/`apply_sign_test`), read directly: a
// sign test is SUGAR for comparing its receiver against the literal
// integer 0 through the exact same `comparison::apply` algebra `>`/`<`/
// `==` themselves run through (`SIGN_TEST_OPERATORS`, resolver.rb, maps
// each symbol to which comparison it stands for) — not a fourth,
// independent numeric check.
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `SignTest` — see `logical.rs`'s header for why the
// trailing arm is a router-bug guard, not a real refusal path.

use crate::kernel::expr::{interpret as eval, EvalContext, Expr, Value};
use crate::kernel::expression_operators::{arithmetic::require_number, comparison};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::SignTest { op, receiver } = expr else {
        return Err(Refusal::TypeMismatch(format!("sign_test::interpret called with a non-sign-test node {expr:?} — a router bug")));
    };

    // No int/float distinction needed here the way a STATIC compiler
    // would need one — `comparison::apply`/`less_than` already compare
    // through `scalar::numeric` (`f64`) uniformly regardless of which
    // literal type the receiver's value carries.
    let v = eval(receiver, ctx)?;
    require_number(&v, "sign test")?;
    Ok(Value::Bool(comparison::apply(op, &v, &Value::Int(0))?))
}
