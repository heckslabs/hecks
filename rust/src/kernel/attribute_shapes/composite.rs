// Implements the `:composite` branch of `Runtime::Value::Coercion::SHAPES`
// (lib/hecksagain/runtime/value/coercion.rb) — `for_attribute`'s
// `coerced =` line: the attribute's type names a DECLARED value object,
// rebuilt recursively via `Value.build`. By the time an expression is
// being EVALUATED, that rebuilding has already happened (a generated
// struct's own `from_json`/mutation-application built the nested value
// ahead of time) — what this file owns is reading it back:
// `Resolver#fetch`'s own recursive per-segment walk (resolver.rb), one
// dotted-path component at a time, mirrored here as the `Field::Nested`
// half of every `Field` a dotted `Lookup` path can resolve to
// (`expr.rs`'s `lookup`, which calls straight into `step`/`finish`
// below rather than walking `Field` itself).

use crate::kernel::expr::{eval_error, Field, Value};
use crate::kernel::Refusal;

/// One segment further into a nested value object — `obj.field(seg)`,
/// Ruby's own recursion inside `Resolver#fetch`. `head` (the FIRST path
/// segment) is carried through only for the "no such nested field"
/// wording; `path` (the WHOLE dotted string) only for "the field so far
/// isn't an object to walk further into" — matching `lookup`'s own two
/// distinct messages exactly.
pub fn step<'a>(current: Field<'a>, seg: &str, head: &str, path: &str) -> Result<Field<'a>, Refusal> {
    match current {
        Field::Nested(obj) => obj.field(seg).ok_or_else(|| eval_error(format!("cannot resolve {seg:?} on {head:?}"))),
        Field::Value(v) => Err(eval_error(format!("{path} — cannot look up {seg:?} on scalar {v:?}"))),
    }
}

/// The path has run out of segments — `current` is either the scalar the
/// whole dotted path resolved to (the ordinary case, every real corpus
/// `Lookup`) or still a nested object (a path that names a value object
/// itself rather than one of its fields — nothing generated actually
/// does this, but it's refused rather than silently returning something
/// no `Expr` variant expects).
pub fn finish(current: Field<'_>, path: &str) -> Result<Value, Refusal> {
    match current {
        Field::Value(v) => Ok(v),
        Field::Nested(_) => Err(eval_error(format!("{path} resolved to an object, not a scalar"))),
    }
}
