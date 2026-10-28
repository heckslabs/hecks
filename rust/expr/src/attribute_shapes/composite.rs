// The `:composite` shape of `Runtime::Value::Coercion::SHAPES`: per-segment dotted-path walking.

use crate::expr::{eval_error, Field, Value};
use crate::rendering;
use crate::Refusal;

/// Ruby's `Resolver.walk_path`, one segment at a time. A nested object reads the field; a string
/// answers the segment when it is a substring (`String#[]`), else nil; a list or an integer cannot
/// be indexed by name and refuses; nil, floats and booleans end the walk in nil, which is what makes
/// `flag.nil?` read as a value instead of a refusal.
pub fn step<'a>(current: &Field<'a>, seg: &str, head: &str) -> Result<Field<'a>, Refusal> {
    match current {
        Field::Nested(obj) => (*obj)
            .field(seg)
            .ok_or_else(|| eval_error(format!("cannot resolve {seg:?} on {head:?}"))),
        Field::Value(v) => step_value(v, seg),
    }
}

fn step_value<'a>(value: &Value, seg: &str) -> Result<Field<'a>, Refusal> {
    match value {
        Value::Str(text) if text.contains(seg) => Ok(Field::Value(Value::Str(seg.to_string()))),
        Value::Str(_) | Value::Nil | Value::Float(_) | Value::Bool(_) => {
            Ok(Field::Value(Value::Nil))
        }
        Value::Object(fields) => Ok(Field::Value(fields.get(seg).cloned().unwrap_or(Value::Nil))),
        Value::Int(_) | Value::List(_) | Value::Array(_) => Err(eval_error(format!(
            "cannot read {} from {}",
            rendering::ruby_inspect(seg),
            rendering::describe(value)
        ))),
    }
}

/// A path may end on a nested object only if it collapses via `Fielded::as_scalar` (or reads as an
/// object value through `Fielded::to_value`).
pub fn finish(current: Field<'_>, path: &str) -> Result<Value, Refusal> {
    match current {
        Field::Value(v) => Ok(v),
        Field::Nested(obj) => obj
            .as_scalar()
            .or_else(|| obj.to_value())
            .ok_or_else(|| eval_error(format!("{path} resolved to an object, not a scalar"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::expr::Fielded;

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
    fn stepped_value(current: &Field<'_>, seg: &str, head: &str) -> Value {
        finish(step(current, seg, head).unwrap(), "test.path").unwrap()
    }

    #[test]
    fn a_further_segment_on_a_bool_scalar_resolves_to_nil_not_a_refusal() {
        // `.nil?` has no dedicated node, so it arrives as a trailing segment on a resolved scalar.
        assert_eq!(
            stepped_value(
                &Field::Value(Value::Bool(true)),
                "nil?",
                "previous_sessions"
            ),
            Value::Nil
        );
    }

    #[test]
    fn this_holds_for_a_false_scalar_too() {
        assert_eq!(
            stepped_value(
                &Field::Value(Value::Bool(false)),
                "nil?",
                "previous_sessions"
            ),
            Value::Nil
        );
    }

    #[test]
    fn floats_strings_without_the_segment_and_nil_end_the_walk_in_nil() {
        for value in [Value::Float(1.5), Value::Str("x".to_string()), Value::Nil] {
            assert_eq!(
                stepped_value(&Field::Value(value.clone()), "nil?", "head"),
                Value::Nil,
                "expected Nil for {value:?}"
            );
        }
    }

    #[test]
    fn a_string_answers_a_segment_it_contains_as_ruby_string_index_does() {
        assert_eq!(
            stepped_value(&Field::Value(Value::Str("abc".to_string())), "bc", "head"),
            Value::Str("bc".to_string())
        );
    }

    #[test]
    fn an_integer_or_a_list_cannot_be_read_by_name_and_refuses() {
        for value in [Value::Int(0), Value::List(3), Value::Array(vec![])] {
            let stepped = step(&Field::Value(value.clone()), "nil?", "head");
            assert!(stepped.is_err(), "expected a refusal for {value:?}");
        }
    }

    #[test]
    fn a_further_segment_on_an_already_nil_value_stays_nil() {
        // An unset optional field already reads as `Nil` before `step` runs.
        assert_eq!(
            stepped_value(&Field::Value(Value::Nil), "nil?", "superseded_by"),
            Value::Nil
        );
    }

    #[test]
    fn a_real_nested_field_still_walks_normally() {
        let customer = Customer {
            status: "active".to_string(),
        };
        assert_eq!(
            stepped_value(&Field::Nested(&customer), "status", "customer"),
            Value::Str("active".to_string())
        );
    }

    #[test]
    fn an_unknown_nested_field_still_refuses() {
        // A generated `field()` is exhaustive, so an unknown name is a codegen bug: keep refusing.
        let customer = Customer {
            status: "active".to_string(),
        };
        let stepped = step(&Field::Nested(&customer), "not_a_real_field", "customer");
        assert!(stepped.is_err());
    }

    #[test]
    fn finish_unwraps_a_resolved_nil_to_a_plain_value() {
        assert_eq!(
            finish(Field::Value(Value::Nil), "previous_sessions.nil?").unwrap(),
            Value::Nil
        );
    }
}
