// The `:composite` shape of `Runtime::Value::Coercion::SHAPES`: per-segment dotted-path walking.

use crate::kernel::expr::{eval_error, Field, Value};
use crate::kernel::Refusal;

/// A scalar (or `Nil`) with segments left resolves to `Nil`, like Ruby's `walk_path`.
/// This makes `flag.nil?` read as a value instead of a refusal.
pub fn step<'a>(current: Field<'a>, seg: &str, head: &str) -> Result<Field<'a>, Refusal> {
    match current {
        Field::Nested(obj) => obj.field(seg).ok_or_else(|| eval_error(format!("cannot resolve {seg:?} on {head:?}"))),
        Field::Value(_) => Ok(Field::Value(Value::Nil)),
    }
}

/// A path may end on a nested object only if it collapses via `Fielded::as_scalar`.
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

    // Hand-built stand-in for a generated composite's `Fielded` impl.
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

    // `Field` derives neither `Debug` nor `PartialEq`; assertions compare the `finish`ed `Value`.
    fn stepped_value(current: Field<'_>, seg: &str, head: &str) -> Value {
        finish(step(current, seg, head).unwrap(), "test.path").unwrap()
    }

    #[test]
    fn a_further_segment_on_a_bool_scalar_resolves_to_nil_not_a_refusal() {
        // `.nil?` has no dedicated node, so it arrives as a trailing segment on a resolved scalar.
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
        // An unset optional field already reads as `Nil` before `step` runs.
        assert_eq!(stepped_value(Field::Value(Value::Nil), "nil?", "superseded_by"), Value::Nil);
    }

    #[test]
    fn a_real_nested_field_still_walks_normally() {
        let customer = Customer { status: "active".to_string() };
        assert_eq!(stepped_value(Field::Nested(&customer), "status", "customer"), Value::Str("active".to_string()));
    }

    #[test]
    fn an_unknown_nested_field_still_refuses() {
        // A generated `field()` is exhaustive, so an unknown name is a codegen bug: keep refusing.
        let customer = Customer { status: "active".to_string() };
        let stepped = step(Field::Nested(&customer), "not_a_real_field", "customer");
        assert!(stepped.is_err());
    }

    #[test]
    fn finish_unwraps_a_resolved_nil_to_a_plain_value() {
        assert_eq!(finish(Field::Value(Value::Nil), "previous_sessions.nil?").unwrap(), Value::Nil);
    }
}
