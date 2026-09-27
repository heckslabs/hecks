//! Interprets `.first` and `.last` over an Array value or a list-typed field lookup.

use crate::kernel::expr::{eval_error, interpret as eval, lookup_items, EvalContext, Expr, Field, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let (op, receiver, take_first) = match expr {
        Expr::First(receiver) => ("first", receiver, true),
        Expr::Last(receiver) => ("last", receiver, false),
        _ => return Err(Refusal::TypeMismatch(format!("positional::interpret called with a non-positional node {expr:?} — a router bug"))),
    };

    match receiver.as_ref() {
        Expr::Lookup(path) => {
            // `Value::List` carries only a length, so read the elements directly.
            let items = lookup_items(path, ctx, op)?;
            field_value(if take_first { items.into_iter().next() } else { items.into_iter().last() }, op)
        }
        other => match eval(other, ctx)? {
            Value::Array(mut elements) => {
                Ok(if take_first {
                    elements.into_iter().next()
                } else {
                    elements.pop()
                }
                .unwrap_or(Value::Nil))
            }
            v => Err(eval_error(format!("{op} expects a list, got {v:?}"))),
        },
    }
}

/// The element `lookup_items` returned; an empty list is nil, as in Ruby.
/// A `Field::Nested` element has no `Value` shape, so it refuses.
fn field_value(item: Option<Field<'_>>, op: &str) -> Result<Value, Refusal> {
    match item {
        None => Ok(Value::Nil),
        Some(Field::Value(v)) => Ok(v),
        Some(Field::Nested(_)) => Err(eval_error(format!("{op} on a list of objects is not generated yet — only scalar-element lists are"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::{Fielded, NoFields};

    fn run(expr: Expr, instance: &dyn Fielded) -> Value {
        let ctx = EvalContext { args: &NoFields, instance };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn first_and_last_over_an_array_literal() {
        let arr = Expr::Array(vec![Expr::Int(1), Expr::Int(2), Expr::Int(3)]);
        assert_eq!(run(Expr::First(Box::new(arr.clone())), &NoFields), Value::Int(1));
        assert_eq!(run(Expr::Last(Box::new(arr)), &NoFields), Value::Int(3));
    }

    #[test]
    fn first_and_last_over_an_empty_array_literal_answer_nil() {
        let arr = Expr::Array(vec![]);
        assert_eq!(run(Expr::First(Box::new(arr.clone())), &NoFields), Value::Nil);
        assert_eq!(run(Expr::Last(Box::new(arr)), &NoFields), Value::Nil);
    }

    #[test]
    fn first_and_last_compose_with_split() {
        let phrase = Expr::Split { receiver: Box::new(Expr::Str("a::b::c".to_string())), separator: "::".to_string() };
        assert_eq!(run(Expr::Last(Box::new(phrase.clone())), &NoFields), Value::Str("c".to_string()));
        assert_eq!(run(Expr::First(Box::new(phrase)), &NoFields), Value::Str("a".to_string()));
    }

    struct Tags {
        values: Vec<String>,
    }
    impl Fielded for Tags {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            (name == "tags").then(|| Field::Value(Value::List(self.values.len())))
        }
        fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
            (name == "tags").then(|| self.values.iter().map(|t| Field::Value(Value::Str(t.clone()))).collect())
        }
    }

    #[test]
    fn first_over_a_real_scalar_element_field() {
        let tags = Tags { values: vec!["a".to_string(), "b".to_string()] };
        assert_eq!(run(Expr::First(Box::new(Expr::Lookup("tags"))), &tags), Value::Str("a".to_string()));
        assert_eq!(run(Expr::Last(Box::new(Expr::Lookup("tags"))), &tags), Value::Str("b".to_string()));
    }

    #[test]
    fn first_over_an_empty_field_answers_nil() {
        let tags = Tags { values: vec![] };
        assert_eq!(run(Expr::First(Box::new(Expr::Lookup("tags"))), &tags), Value::Nil);
    }

    struct Leg {
        origin: String,
    }
    impl Fielded for Leg {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            (name == "origin").then(|| Field::Value(Value::Str(self.origin.clone())))
        }
    }
    struct Itinerary {
        legs: Vec<Leg>,
    }
    impl Fielded for Itinerary {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            (name == "legs").then(|| Field::Value(Value::List(self.legs.len())))
        }
        fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
            (name == "legs").then(|| self.legs.iter().map(|leg| Field::Nested(leg)).collect())
        }
    }

    #[test]
    fn first_over_a_list_of_objects_refuses_by_name_instead_of_misrepresenting_one() {
        let itinerary = Itinerary { legs: vec![Leg { origin: "SFO".to_string() }] };
        let ctx = EvalContext { args: &NoFields, instance: &itinerary };
        let err = eval(&Expr::First(Box::new(Expr::Lookup("legs"))), &ctx).unwrap_err();
        assert!(format!("{err:?}").contains("not generated yet"), "{err:?}");
    }
}
