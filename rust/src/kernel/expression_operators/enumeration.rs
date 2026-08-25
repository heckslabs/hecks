// THE "enumeration" OPERATOR CATEGORY — `.any?`/`.none?`/`.all?` and
// `.find`, each taking a `{ |param| predicate }` block; the port of
// `Resolver#evaluate_block_predicate`/`#found_of`
// (lib/hecks/bluebook/expression/resolver/block_predicates.rb), read
// directly. Admitted into the expression ledger as one category
// (`lib/hecks/grammar/expression_operators.json`, strategy
// `block_pattern_match`) the day the first domain to lean on them —
// chess, whose every occupancy, path-clearance and check-safety given
// is one, three deep — asked to be projected to Rust and the generator
// refused with "unhandled resolver node BlockPredicate". A block's
// parameter is bound by `Bound` (expr.rs) exactly as Ruby merges it
// into attrs; the receiver's ELEMENTS come from `Fielded::items`, the
// second reading of a list field beside `Value::List(len)`.
//
// Every element's outcome is computed BEFORE the aggregation, not
// short-circuited — Ruby's own `collection.map { … }` then `.all?`/
// `.any?`/`.none?` does the same, so an evaluation error on the third
// element surfaces identically in both runtimes.
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
            // `return nil if found.nil?` — nothing matched, and a path
            // walked from nothing is nil too.
            Ok(Value::Nil)
        }
        _ => Err(Refusal::TypeMismatch(format!("enumeration::interpret called with a non-enumeration node {expr:?} — a router bug"))),
    }
}

/// The receiver must be a `Lookup` — the only node that names a list
/// field. Anything else is evaluated for the wording only: Ruby raises
/// "any? expects a list, got …" for a non-Array receiver.
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

/// `found_of`'s tail: `unwrap_scalar(found)` for a bare `.find { }`,
/// `unwrap_scalar(walk_path(found, path))` otherwise — the same
/// `composite::step`/`finish` walk a dotted `Lookup` takes past its head.
fn project(item: Field<'_>, path: &[&str]) -> Result<Value, Refusal> {
    let mut current = item;
    let rendered = path.join(".");
    for seg in path {
        current = composite::step(current, seg, "find", &rendered)?;
    }
    composite::finish(current, &format!("find {{ }}.{rendered}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kernel::expr::{Fielded, NoFields};
    use crate::kernel::Comparison;

    // A hand-built host, shaped like the generated `Fielded` impls
    // fielded.rb emits: `field` answers the list as its length, `items`
    // answers its members.
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
        // `number` on the instance is 99; inside the block `number` is
        // NOT the parameter (the parameter is `s`), so it still reads 99
        // — while `s.number` reads the element's own.
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
        // seats.any? { |s| s.taken == false && seats.none? { |o| o.number == s.number + 1 } }
        // — the free seat (2) is followed by seat 3, so this is false;
        // the inner block reads BOTH its own `o` and the outer `s`.
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
