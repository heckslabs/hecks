// Implements the `:composite` branch of `Runtime::Value::Coercion::SHAPES`
// (lib/hecks/runtime/value/coercion.rb) — `for_attribute`'s
// `coerced =` line: the attribute's type names a declared value object,
// rebuilt recursively via `Value.build`. By the time an expression is
// being evaluated, that rebuilding has already happened (a generated
// struct's own `from_json`/mutation-application built the nested value
// ahead of time) — what this file owns is reading it back:
// `Resolver#fetch`'s own recursive per-segment walk (resolver.rb), one
// dotted-path component at a time, mirrored here as the `Field::Nested`
// half of every `Field` a dotted `Lookup` path can resolve to
// (`expr.rs`'s `lookup`, which calls straight into `step`/`finish`
// below rather than walking `Field` itself).

use crate::kernel::expr::{eval_error, Field, Value};
use crate::kernel::Refusal;

/// One segment further along a dotted path. `Field::Nested` walks one more
/// level via `obj.field(seg)`, Ruby's own recursion inside `Resolver#fetch`;
/// `head` (the first path segment) is carried through only for that
/// branch's "no such nested field" wording.
///
/// `Field::Value` — the path still has a segment left, but the value
/// already in hand is a scalar (or `Value::Nil` itself) — is
/// `Resolver#walk_path`'s own `break nil unless current.respond_to?(:[])`
/// (resolver.rb, read directly): a scalar never responds to `#[]`, so
/// Ruby stops walking right there and every remaining segment answers
/// `nil`, never an error. This is the whole of what a real corpus
/// `!some_attribute.nil?` invariant means — `.nil?` has no dedicated node
/// in this grammar (`resolver.rb`'s own `parse` has no `.nil?` suffix
/// rule), so it parses as an ordinary trailing `Lookup` segment, and its
/// entire job is this fallthrough: `previous_sessions.nil?` reaches here
/// once `previous_sessions` has already resolved to `Field::Value(Bool
/// (true))`, and answering `Field::Value(Value::Nil)` (rather than
/// refusing) is what makes `!previous_sessions.nil?` read `true` for a
/// present boolean, matching Ruby exactly. The same fallthrough also
/// answers a genuinely absent/optional field's own `.nil?` correctly:
/// an unset field already reads as `Field::Value(Value::Nil)` before this
/// step ever runs, and a further `.nil?` on it stays `Value::Nil` here
/// too — `finish`, below, hands either case back as a plain `Value`, no
/// further dispatch on `seg`'s own spelling needed.
pub fn step<'a>(current: Field<'a>, seg: &str, head: &str) -> Result<Field<'a>, Refusal> {
    match current {
        Field::Nested(obj) => obj.field(seg).ok_or_else(|| eval_error(format!("cannot resolve {seg:?} on {head:?}"))),
        Field::Value(_) => Ok(Field::Value(Value::Nil)),
    }
}

/// The path has run out of segments — `current` is either the scalar the
/// whole dotted path resolved to (the ordinary case, every real corpus
/// `Lookup`), or still a nested object (a path that names a value object
/// or a dereferenced reference itself rather than one of its own
/// fields). `Fielded::as_scalar` (expr.rs) is that object's own optional
/// "collapse me to a comparable scalar" reading — `DerefNode`'s own
/// override (`reference_lookup.rs`) is the real, live example (`source
/// != destination`); everything else still answers `None`, so a bare
/// nested-VO lookup this corpus never actually needs still refuses the
/// same way it always has, rather than silently returning something no
/// `Expr` variant expects.
pub fn finish(current: Field<'_>, path: &str) -> Result<Value, Refusal> {
    match current {
        Field::Value(v) => Ok(v),
        Field::Nested(obj) => obj.as_scalar().ok_or_else(|| eval_error(format!("{path} resolved to an object, not a scalar"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::Fielded;

    // A hand-built nested value object, shaped like a generated composite
    // attribute's own `Fielded` impl: one real field, nothing else.
    struct Customer {
        status: String,
    }
    impl Fielded for Customer {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match name {
                "status" => Some(Field::Value(Value::Str(self.status.clone()))),
                _ => None,
            }
        }
    }

    // `Field` carries a `&dyn Fielded` and derives neither `Debug` nor
    // `PartialEq` (see its own definition, expr.rs), so every assertion
    // below routes the stepped result through `finish` — the same plain
    // `Value` a real `Lookup` walk ends on — rather than comparing `Field`
    // itself.
    fn stepped_value(current: Field<'_>, seg: &str, head: &str) -> Value {
        finish(step(current, seg, head).unwrap(), "test.path").unwrap()
    }

    #[test]
    fn a_further_segment_on_a_bool_scalar_resolves_to_nil_not_a_refusal() {
        // `previous_sessions.nil?` — the live bug: `previous_sessions`
        // resolves to a plain boolean, and `.nil?` is not a dedicated
        // node in this grammar, so it arrives here as an ordinary
        // trailing segment on an already-resolved scalar.
        assert_eq!(stepped_value(Field::Value(Value::Bool(true)), "nil?", "previous_sessions"), Value::Nil);
    }

    #[test]
    fn this_holds_for_a_false_scalar_too() {
        assert_eq!(stepped_value(Field::Value(Value::Bool(false)), "nil?", "previous_sessions"), Value::Nil);
    }

    #[test]
    fn this_holds_for_every_scalar_shape_not_just_bool() {
        for value in [Value::Int(0), Value::Float(1.5), Value::Str("x".to_string()), Value::List(3)] {
            assert_eq!(stepped_value(Field::Value(value.clone()), "nil?", "head"), Value::Nil, "expected Nil for {value:?}");
        }
    }

    #[test]
    fn a_further_segment_on_an_already_nil_value_stays_nil() {
        // A genuinely absent/optional field already resolves to
        // `Field::Value(Value::Nil)` before `step` ever runs (see
        // `json.rs`'s own `Json::Null => Field::Value(Value::Nil)` and
        // every generated struct's `.or(Some(Field::Value(Value::Nil)))`
        // for an unset composite field) — a further `.nil?` on it must
        // stay `Nil`, the same fallthrough as a present scalar.
        assert_eq!(stepped_value(Field::Value(Value::Nil), "nil?", "superseded_by"), Value::Nil);
    }

    #[test]
    fn a_real_nested_field_still_walks_normally() {
        let customer = Customer { status: "active".to_string() };
        assert_eq!(stepped_value(Field::Nested(&customer), "status", "customer"), Value::Str("active".to_string()));
    }

    #[test]
    fn an_unknown_nested_field_still_refuses() {
        // Unlike a dynamic Ruby Hash, a generated struct's `field()` is
        // exhaustive over its real declared attributes — an unresolved
        // name here is a codegen bug, not a legitimate absent key, so
        // this path is deliberately left refusing.
        let customer = Customer { status: "active".to_string() };
        let stepped = step(Field::Nested(&customer), "not_a_real_field", "customer");
        assert!(stepped.is_err());
    }

    #[test]
    fn finish_unwraps_a_resolved_nil_to_a_plain_value() {
        assert_eq!(finish(Field::Value(Value::Nil), "previous_sessions.nil?").unwrap(), Value::Nil);
    }
}
