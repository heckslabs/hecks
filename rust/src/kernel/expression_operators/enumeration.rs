//! `.any?`/`.none?`/`.all?` and `.find`, each taking a `{ |param| predicate }` block.

// Every element is evaluated before aggregating, not short-circuited, so an error on any
// element surfaces exactly as it does in Ruby.
use crate::kernel::attribute_shapes::composite;
use crate::kernel::expr::{eval_error, interpret as eval, lookup_items, BlockMode, Bound, EvalContext, Expr, Field, Value};
use crate::kernel::Refusal;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    match expr {
        Expr::BlockPredicate { mode, receiver, param, predicate } => {
            let items = elements(receiver, ctx, mode.ruby_name())?;
            let mut outcomes = Vec::with_capacity(items.len());
            for item in items {
                let bound = Bound { name: param, value: item, rest: ctx.args };
                let inner = EvalContext { args: &bound, instance: ctx.instance };
                outcomes.push(eval(predicate, &inner)?.truthy());
            }
            Ok(Value::Bool(match mode {
                BlockMode::All => outcomes.iter().all(|b| *b),
                BlockMode::Any => outcomes.iter().any(|b| *b),
                BlockMode::None => !outcomes.iter().any(|b| *b),
            }))
        }
        Expr::Find { receiver, param, predicate, path } => {
            let items = elements(receiver, ctx, "find")?;
            for item in items {
                let accepted = {
                    let bound = Bound { name: param, value: borrow(&item), rest: ctx.args };
                    let inner = EvalContext { args: &bound, instance: ctx.instance };
                    eval(predicate, &inner)?.truthy()
                };
                if accepted {
                    return project(item, path);
                }
            }
            // Nothing matched, and a path walked from nothing is nil too.
            Ok(Value::Nil)
        }
        _ => Err(Refusal::TypeMismatch(format!("enumeration::interpret called with a non-enumeration node {expr:?} — a router bug"))),
    }
}

/// Only a `Lookup` names a list field; any other receiver is evaluated just to word the error.
fn elements<'a>(receiver: &Expr, ctx: &EvalContext<'a>, op: &str) -> Result<Vec<Field<'a>>, Refusal> {
    match receiver {
        Expr::Lookup(path) => lookup_items(path, ctx, op),
        other => {
            let v = eval(other, ctx)?;
            Err(eval_error(format!("{op} expects a list, got {v:?}")))
        }
    }
}

fn borrow<'a>(field: &Field<'a>) -> Field<'a> {
    match field {
        Field::Value(v) => Field::Value(v.clone()),
        Field::Nested(obj) => Field::Nested(*obj),
    }
}

/// Walks `path` past the found element, as a dotted `Lookup` does past its head.
fn project(item: Field<'_>, path: &[&str]) -> Result<Value, Refusal> {
    let mut current = item;
    let rendered = path.join(".");
    for seg in path {
        current = composite::step(current, seg, "find")?;
    }
    composite::finish(current, &format!("find {{ }}.{rendered}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::{Fielded, NoFields};
    use crate::kernel::Comparison;

    // Shaped like generated `Fielded` impls: `field` answers a list's length, `items` its members.
    struct Seat {
        number: i64,
        taken: bool,
    }
    impl Fielded for Seat {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match name {
                "number" => Some(Field::Value(Value::Int(self.number))),
                "taken" => Some(Field::Value(Value::Bool(self.taken))),
                _ => None,
            }
        }
    }
    struct Roster {
        seats: Vec<Seat>,
        tags: Vec<String>,
        number: i64,
    }
    impl Fielded for Roster {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match name {
                "seats" => Some(Field::Value(Value::List(self.seats.len()))),
                "tags" => Some(Field::Value(Value::List(self.tags.len()))),
                "number" => Some(Field::Value(Value::Int(self.number))),
                _ => None,
            }
        }
        fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
            match name {
                "seats" => Some(self.seats.iter().map(|s| Field::Nested(s)).collect()),
                "tags" => Some(self.tags.iter().map(|t| Field::Value(Value::Str(t.clone()))).collect()),
                _ => None,
            }
        }
    }

    fn roster() -> Roster {
        Roster {
            seats: vec![Seat { number: 1, taken: true }, Seat { number: 2, taken: false }, Seat { number: 3, taken: true }],
            tags: vec!["a".to_string(), "".to_string()],
            number: 99,
        }
    }

    const EQ: Comparison = Comparison { less_than: false, equal: true, negated: false };

    fn eq(left: Expr, right: Expr) -> Expr {
        Expr::Compare { op: EQ, left: Box::new(left), right: Box::new(right) }
    }

    fn run(expr: &Expr, instance: &dyn Fielded) -> Value {
        let ctx = EvalContext { args: &NoFields, instance };
        eval(expr, &ctx).expect("evaluates")
    }

    #[test]
    fn any_none_all_over_nested_elements() {
        let free = |mode| Expr::BlockPredicate {
            mode,
            receiver: Box::new(Expr::Lookup("seats")),
            param: "s",
            predicate: Box::new(eq(Expr::Lookup("s.taken"), Expr::Bool(false))),
        };
        let r = roster();
        assert_eq!(run(&free(BlockMode::Any), &r), Value::Bool(true));
        assert_eq!(run(&free(BlockMode::None), &r), Value::Bool(false));
        assert_eq!(run(&free(BlockMode::All), &r), Value::Bool(false));
    }

    #[test]
    fn scalar_lists_bind_the_element_itself() {
        let blank = Expr::BlockPredicate {
            mode: BlockMode::Any,
            receiver: Box::new(Expr::Lookup("tags")),
            param: "t",
            predicate: Box::new(Expr::Empty(Box::new(Expr::Lookup("t")))),
        };
        assert_eq!(run(&blank, &roster()), Value::Bool(true));
    }

    #[test]
    fn an_empty_list_answers_like_ruby() {
        let empty = Roster { seats: vec![], tags: vec![], number: 0 };
        let over = |mode| Expr::BlockPredicate {
            mode,
            receiver: Box::new(Expr::Lookup("seats")),
            param: "s",
            predicate: Box::new(Expr::Bool(true)),
        };
        assert_eq!(run(&over(BlockMode::All), &empty), Value::Bool(true));
        assert_eq!(run(&over(BlockMode::Any), &empty), Value::Bool(false));
        assert_eq!(run(&over(BlockMode::None), &empty), Value::Bool(true));
    }

    #[test]
    fn the_parameter_shadows_a_same_named_field_only_inside_the_block() {
        // Inside the block `number` still reads the instance's 99; only `s` is bound.
        let shadow = Expr::BlockPredicate {
            mode: BlockMode::Any,
            receiver: Box::new(Expr::Lookup("seats")),
            param: "s",
            predicate: Box::new(Expr::And(
                Box::new(eq(Expr::Lookup("number"), Expr::Int(99))),
                Box::new(eq(Expr::Lookup("s.number"), Expr::Int(2))),
            )),
        };
        assert_eq!(run(&shadow, &roster()), Value::Bool(true));
    }

    #[test]
    fn nested_blocks_see_the_outer_parameter() {
        // The free seat (2) is followed by seat 3, so this is false; the inner block reads
        // both its own `o` and the outer `s`.
        let inner = Expr::BlockPredicate {
            mode: BlockMode::None,
            receiver: Box::new(Expr::Lookup("seats")),
            param: "o",
            predicate: Box::new(eq(Expr::Lookup("o.number"), Expr::Add(Box::new(Expr::Lookup("s.number")), Box::new(Expr::Int(1))))),
        };
        let outer = Expr::BlockPredicate {
            mode: BlockMode::Any,
            receiver: Box::new(Expr::Lookup("seats")),
            param: "s",
            predicate: Box::new(Expr::And(Box::new(eq(Expr::Lookup("s.taken"), Expr::Bool(false))), Box::new(inner))),
        };
        assert_eq!(run(&outer, &roster()), Value::Bool(false));
    }

    #[test]
    fn find_projects_through_its_path_and_answers_nil_when_nothing_matches() {
        let free_number = |wanted: bool| Expr::Find {
            receiver: Box::new(Expr::Lookup("seats")),
            param: "s",
            predicate: Box::new(eq(Expr::Lookup("s.taken"), Expr::Bool(wanted))),
            path: &["number"],
        };
        assert_eq!(run(&free_number(false), &roster()), Value::Int(2));
        let none_free = Roster { seats: vec![Seat { number: 1, taken: true }], tags: vec![], number: 0 };
        assert_eq!(run(&free_number(false), &none_free), Value::Nil);
    }

    #[test]
    fn a_non_list_receiver_refuses_with_the_operator_named() {
        let wrong = Expr::BlockPredicate {
            mode: BlockMode::Any,
            receiver: Box::new(Expr::Lookup("number")),
            param: "n",
            predicate: Box::new(Expr::Bool(true)),
        };
        let ctx = EvalContext { args: &NoFields, instance: &roster() };
        let err = eval(&wrong, &ctx).unwrap_err();
        assert!(format!("{err:?}").contains("any? expects a list"), "{err:?}");
    }
}
