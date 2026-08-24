// Implements the `:optional` branch of `Runtime::Value::Coercion::SHAPES`
// (lib/hecks/runtime/value/coercion.rb) — `for_attribute`'s own
// FIRST check, `return value if attribute.nil? || value.nil?`: an
// attribute that was never supplied arrives as Ruby's `nil`, unchanged —
// no value object ever gets a chance to run its own coercion or
// invariants on something that was never there.
//
// This kernel's `Value::Nil` is that same "not there" — built the
// identical way whether the source was a declared-`optional:` field left
// unset OR a literal `nil` written in canonical text
// (`Resolver::NilLiteral`, `Expr::Nil`). Ruby draws no distinction
// between the two once evaluation actually starts (`nil` is `nil`,
// regardless of why), so neither does this file.

use crate::kernel::expr::Value;

/// `nil.to_s == ""` — `Resolver::ToS`'s one non-scalar case
/// (`expression_operators::to_string` tries `scalar::to_s` first, falls
/// back to this). `None` for anything that isn't `Value::Nil`.
pub fn to_s(v: &Value) -> Option<Value> {
    matches!(v, Value::Nil).then(|| Value::Str(String::new()))
}
