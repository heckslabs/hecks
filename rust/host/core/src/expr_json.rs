//! The host's JSON door to the expression evaluator it shares with the kernel (`hecks_expr`):
//! `parse` reads an invariant's `ast` node into the shared `Expr`, and `interpret` evaluates it
//! over an instance read as JSON, with the Ruby runtime's semantics (`Evaluator`/`Resolver`): the
//! same answers, null handling and error wording, so a value object's invariants mint the same way.
//!
//! There is one evaluator. What is the host's own is the reading of data: the AST arrives as JSON
//! with owned names, and the instance is a JSON object rather than a generated struct.

use hecks_expr::expr::{
    self as shared, BlockMode, Comparison, EvalContext, Field, Fielded, NoFields, StripSide,
};
pub use hecks_expr::expr::{Expr, Value};
use serde_json::Value as Json;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Mutex, OnceLock, PoisonError};

/// The `'static` spelling of a name, shared by every parse of it. The shared `Expr` holds names as
/// `&'static str` (generated code writes them as literals); an IR's names are a finite set, so each
/// distinct one is leaked once and a repeated parse costs nothing more.
fn intern(text: &str) -> &'static str {
    static NAMES: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();
    let mut names = NAMES
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if let Some(known) = names.get(text) {
        return known;
    }
    let leaked: &'static str = Box::leak(text.to_string().into_boxed_str());
    names.insert(leaked);
    leaked
}

/// The `'static` spelling of a path of segments, interned the same way.
fn intern_path(segments: &[String]) -> &'static [&'static str] {
    static PATHS: OnceLock<Mutex<HashMap<Vec<String>, &'static [&'static str]>>> = OnceLock::new();
    let mut paths = PATHS
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if let Some(known) = paths.get(segments) {
        return known;
    }
    let interned: Vec<&'static str> = segments.iter().map(|s| intern(s)).collect();
    let leaked: &'static [&'static str] = Box::leak(interned.into_boxed_slice());
    paths.insert(segments.to_vec(), leaked);
    leaked
}

/// Parses an invariant's `ast` node into an `Expr`.
///
/// One JSON object per node, tagged by `"op"`; field names match the Hash keys `ast_json.rb`
/// emits. An unrecognized `"op"`, or a malformed shape under a known one, is an `Err`.
pub fn parse(json: &Json) -> Result<Expr, String> {
    let op = json
        .get("op")
        .and_then(Json::as_str)
        .ok_or_else(|| format!("{json} has no string \"op\" field"))?;

    let field = |name: &str| {
        json.get(name)
            .ok_or_else(|| format!("{op} node has no {name:?} field: {json}"))
    };
    let expr = |name: &str| parse(field(name)?);
    let boxed = |name: &str| -> Result<Box<Expr>, String> { Ok(Box::new(expr(name)?)) };
    let str_field = |name: &str| -> Result<String, String> {
        field(name)?
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| format!("{op}'s {name:?} isn't a string: {json}"))
    };
    let bool_field = |name: &str| -> Result<bool, String> {
        field(name)?
            .as_bool()
            .ok_or_else(|| format!("{op}'s {name:?} isn't a boolean: {json}"))
    };
    // `lookup.path` and `find.path` are segment arrays, never dotted strings.
    let path_field = |name: &str| -> Result<Vec<String>, String> {
        field(name)?
            .as_array()
            .ok_or_else(|| format!("{op}'s {name:?} isn't an array: {json}"))?
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_string)
                    .ok_or_else(|| format!("{op}'s {name:?} has a non-string element: {json}"))
            })
            .collect::<Result<Vec<_>, _>>()
    };
    let comparison = || -> Result<Comparison, String> {
        let cmp = field("cmp")?;
        let flag = |name: &str| {
            cmp.get(name)
                .and_then(Json::as_bool)
                .ok_or_else(|| format!("{op}'s cmp has no {name}: {json}"))
        };
        Ok(Comparison {
            less_than: flag("less_than")?,
            equal: flag("equal")?,
            negated: flag("negated")?,
        })
    };

    Ok(match op {
        "or" => Expr::Or(boxed("left")?, boxed("right")?),
        "and" => Expr::And(boxed("left")?, boxed("right")?),
        "not" => Expr::Not(boxed("expr")?),
        "compare" => Expr::Compare {
            op: comparison()?,
            left: boxed("left")?,
            right: boxed("right")?,
        },
        "include" => Expr::Include {
            haystack: boxed("haystack")?,
            needle: boxed("needle")?,
        },
        "int" => Expr::Int(
            field("value")?
                .as_i64()
                .ok_or_else(|| format!("int's value isn't an integer: {json}"))?,
        ),
        "float" => Expr::Float(
            field("value")?
                .as_f64()
                .ok_or_else(|| format!("float's value isn't a number: {json}"))?,
        ),
        "str" => Expr::Str(str_field("value")?),
        "bool" => Expr::Bool(bool_field("value")?),
        "nil" => Expr::Nil,
        "add" => Expr::Add(boxed("left")?, boxed("right")?),
        "sub" => Expr::Sub(boxed("left")?, boxed("right")?),
        "mul" => Expr::Mul(boxed("left")?, boxed("right")?),
        "div" => Expr::Div(boxed("left")?, boxed("right")?),
        "sign_test" => Expr::SignTest {
            op: comparison()?,
            receiver: boxed("receiver")?,
        },
        "empty" => Expr::Empty(boxed("receiver")?),
        "to_s" => Expr::ToS(boxed("receiver")?),
        "modulo" => Expr::Modulo {
            receiver: boxed("receiver")?,
            divisor: boxed("divisor")?,
        },
        "size" => Expr::Size(boxed("receiver")?),
        "lookup" => Expr::Lookup(intern(&path_field("path")?.join("."))),
        "block_predicate" => Expr::BlockPredicate {
            mode: match str_field("mode")?.as_str() {
                "all" => BlockMode::All,
                "any" => BlockMode::Any,
                "none" => BlockMode::None,
                other => {
                    return Err(format!(
                        "block_predicate's mode {other:?} is none of all/any/none: {json}"
                    ))
                }
            },
            receiver: boxed("receiver")?,
            param: intern(&str_field("param")?),
            predicate: boxed("predicate")?,
        },
        "find" => Expr::Find {
            receiver: boxed("receiver")?,
            param: intern(&str_field("param")?),
            predicate: boxed("predicate")?,
            path: intern_path(&path_field("path")?),
        },
        "sum" => Expr::Sum {
            receiver: boxed("receiver")?,
            param: intern(&str_field("param")?),
            predicate: boxed("predicate")?,
        },
        "array" => Expr::Array(
            field("elements")?
                .as_array()
                .ok_or_else(|| format!("array's elements isn't an array: {json}"))?
                .iter()
                .map(parse)
                .collect::<Result<Vec<_>, _>>()?,
        ),
        "matches_regex" => Expr::MatchesRegex {
            receiver: boxed("receiver")?,
            pattern: str_field("pattern")?,
            flags: str_field("flags")?,
        },
        "presence" => Expr::Presence {
            receiver: boxed("receiver")?,
            negated: bool_field("negated")?,
        },
        "assignment" => Expr::Assignment {
            receiver: boxed("receiver")?,
            negated: bool_field("negated")?,
        },
        "split" => Expr::Split {
            receiver: boxed("receiver")?,
            separator: str_field("separator")?,
        },
        "strip" => Expr::Strip {
            receiver: boxed("receiver")?,
            side: match str_field("side")?.as_str() {
                "both" => StripSide::Both,
                "left" => StripSide::Left,
                "right" => StripSide::Right,
                other => {
                    return Err(format!(
                        "strip's side {other:?} is none of both/left/right: {json}"
                    ))
                }
            },
        },
        "starts_with" => Expr::StartsWith {
            receiver: boxed("receiver")?,
            substring: str_field("substring")?,
        },
        "ends_with" => Expr::EndsWith {
            receiver: boxed("receiver")?,
            substring: str_field("substring")?,
        },
        "first" => Expr::First(boxed("receiver")?),
        "last" => Expr::Last(boxed("receiver")?),
        other => return Err(format!("unrecognized expression op {other:?}: {json}")),
    })
}

/// The value of a JSON scalar, array or object as the evaluator reads it.
fn value_of(json: &Json) -> Result<Value, String> {
    match json {
        Json::Null => Ok(Value::Nil),
        Json::Bool(b) => Ok(Value::Bool(*b)),
        Json::Number(n) => n
            .as_i64()
            .map(Value::Int)
            .or_else(|| n.as_f64().map(Value::Float))
            .ok_or_else(|| format!("{n} is a number this interpreter cannot represent")),
        Json::String(s) => Ok(Value::Str(s.clone())),
        Json::Array(items) => Ok(Value::Array(
            items.iter().map(value_of).collect::<Result<Vec<_>, _>>()?,
        )),
        Json::Object(fields) => Ok(Value::Object(
            fields
                .iter()
                .map(|(key, field)| Ok((key.clone(), value_of(field)?)))
                .collect::<Result<BTreeMap<_, _>, String>>()?,
        )),
    }
}

/// One field of an instance, read the way the evaluator walks it.
enum Slot {
    Scalar(Value),
    Object(Node),
    List(Vec<Self>),
}

impl Slot {
    fn from_json(json: &Json) -> Result<Self, String> {
        match json {
            Json::Object(_) => Ok(Self::Object(Node::from_json(json, false)?)),
            Json::Array(items) => Ok(Self::List(
                items
                    .iter()
                    .map(Self::from_json)
                    .collect::<Result<Vec<_>, _>>()?,
            )),
            scalar => Ok(Self::Scalar(value_of(scalar)?)),
        }
    }

    /// This slot as a plain value, an object slot becoming a `Value::Object`.
    fn value(&self) -> Value {
        match self {
            Self::Scalar(value) => value.clone(),
            Self::Object(node) => node.object_value(),
            Self::List(items) => Value::Array(items.iter().map(Self::value).collect()),
        }
    }

    fn field(&self) -> Field<'_> {
        match self {
            Self::Object(node) => Field::Nested(node),
            other => Field::Value(other.value()),
        }
    }
}

/// An instance object as the evaluator's `Fielded`: the head of a lookup must exist, but a
/// nested object answers nil for a field it lacks (Ruby's `Hash#[]`).
struct Node {
    fields: BTreeMap<String, Slot>,
    root: bool,
}

impl Node {
    fn from_json(json: &Json, root: bool) -> Result<Self, String> {
        let fields = match json {
            Json::Object(fields) => fields
                .iter()
                .map(|(key, field)| Ok((key.clone(), Slot::from_json(field)?)))
                .collect::<Result<BTreeMap<_, _>, String>>()?,
            _ => BTreeMap::new(),
        };
        Ok(Self { fields, root })
    }

    fn object_value(&self) -> Value {
        Value::Object(
            self.fields
                .iter()
                .map(|(key, slot)| (key.clone(), slot.value()))
                .collect(),
        )
    }
}

impl Fielded for Node {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        match self.fields.get(name) {
            Some(slot) => Some(slot.field()),
            None if self.root => None,
            None => Some(Field::Value(Value::Nil)),
        }
    }

    /// `Resolver.unwrap_scalar`: a one-field value object reads as its one value.
    fn as_scalar(&self) -> Option<Value> {
        (self.fields.len() == 1)
            .then(|| self.fields.values().next().map(Slot::value))
            .flatten()
    }

    fn to_value(&self) -> Option<Value> {
        Some(self.object_value())
    }

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        match self.fields.get(name) {
            Some(Slot::List(items)) => Some(items.iter().map(Slot::field).collect()),
            _ => None,
        }
    }
}

/// Evaluates `expr` over `instance`, the JSON object a value object's fields arrived as.
pub fn interpret(expr: &Expr, instance: &Json) -> Result<Value, String> {
    let node = Node::from_json(instance, true)?;
    let ctx = EvalContext {
        args: &node,
        instance: &NoFields,
    };
    shared::interpret(expr, &ctx).map_err(|refusal| refusal.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[allow(clippy::needless_pass_by_value)] // reason: test helper called with inline literals
    fn field(name: &str, value: Json) -> Json {
        serde_json::json!({ name: value })
    }

    #[test]
    fn cents_gte_zero_holds_for_a_non_negative_amount() {
        // `cents >= 0`, the shape `AstJson.emit_predicate` builds.
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":true,"equal":false,"negated":true},
            "left":{"op":"lookup","path":["cents"]},"right":{"op":"int","value":0}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(
            interpret(&expr, &field("cents", serde_json::json!(1200))),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            interpret(&expr, &field("cents", serde_json::json!(0))),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            interpret(&expr, &field("cents", serde_json::json!(-1))),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn a_compound_and_of_four_comparisons_matches_chess_square_bounds() {
        // `file >= 0 && file <= 7 && rank >= 0 && rank <= 7`, chess.bluebook's `Square`.
        fn cmp(
            less_than: bool,
            equal: bool,
            negated: bool,
            field: &str,
            n: i64,
        ) -> serde_json::Value {
            serde_json::json!({"op":"compare","cmp":{"less_than":less_than,"equal":equal,"negated":negated},
                "left":{"op":"lookup","path":[field]},"right":{"op":"int","value":n}})
        }
        let ast = serde_json::json!({"op":"and","left":{"op":"and","left":{"op":"and",
            "left": cmp(true, false, true, "file", 0),
            "right": cmp(true, true, false, "file", 7)},
            "right": cmp(true, false, true, "rank", 0)},
            "right": cmp(true, true, false, "rank", 7)});
        let expr = parse(&ast).expect("valid Expr JSON");

        let on_board = serde_json::json!({"file": 3, "rank": 7});
        let off_board = serde_json::json!({"file": 8, "rank": 0});
        assert_eq!(interpret(&expr, &on_board), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &off_board), Ok(Value::Bool(false)));
    }

    #[test]
    fn a_blank_string_fails_the_not_empty_to_s_pattern() {
        // `!value.to_s.empty?`, the most common real invariant shape.
        let ast = serde_json::json!({"op":"not","expr":{"op":"empty","receiver":{"op":"to_s","receiver":{"op":"lookup","path":["value"]}}}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(
            interpret(&expr, &field("value", serde_json::json!("Margherita"))),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            interpret(&expr, &field("value", serde_json::json!(""))),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn sign_test_positive_matches_a_real_amount_invariant() {
        // `value.positive?` compiles to NOT(value < 0 or value == 0).
        let ast = serde_json::json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":{"op":"lookup","path":["value"]}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(
            interpret(&expr, &field("value", serde_json::json!(5))),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            interpret(&expr, &field("value", serde_json::json!(0))),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            interpret(&expr, &field("value", serde_json::json!(-5))),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn int_and_float_compare_equal_across_kinds_the_same_way_the_kernel_does() {
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":false,"equal":true,"negated":false},
            "left":{"op":"lookup","path":["cents"]},"right":{"op":"float","value":3.0}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(
            interpret(&expr, &field("cents", serde_json::json!(3))),
            Ok(Value::Bool(true))
        );
    }

    #[test]
    fn an_unrecognized_op_refuses_to_parse_rather_than_defaulting() {
        let ast = serde_json::json!({"op":"frobnicate"});
        let err = parse(&ast).unwrap_err();
        assert!(err.contains("unrecognized"), "{err}");
    }

    // Expected values below are real Ruby results (`Resolver.resolve` / `Evaluator.call`); the
    // differential spec `spec/rust_host_expr_json_conformance_spec.rb` re-checks them live.
    use serde_json::json;

    #[allow(clippy::needless_pass_by_value)] // reason: test helper called with inline literals
    fn run(ast: Json, instance: Json) -> Result<Value, String> {
        interpret(&parse(&ast).expect("valid Expr JSON"), &instance)
    }

    fn lookup_of(name: &str) -> Json {
        json!({"op":"lookup","path":[name]})
    }

    fn int(n: i64) -> Json {
        json!({"op":"int","value":n})
    }

    fn string(s: &str) -> Json {
        json!({"op":"str","value":s})
    }

    #[allow(clippy::needless_pass_by_value)] // reason: test helper called with inline literals
    fn call(op: &str, receiver: Json) -> Json {
        json!({"op":op,"receiver":receiver})
    }

    #[allow(clippy::needless_pass_by_value)] // reason: test helper called with inline literals
    fn eq(left: Json, right: Json) -> Json {
        json!({"op":"compare","cmp":{"less_than":false,"equal":true,"negated":false},"left":left,"right":right})
    }

    fn strs(items: &[&str]) -> Value {
        Value::Array(items.iter().map(|s| Value::Str(s.to_string())).collect())
    }

    #[test]
    fn add_sums_numbers_and_promotes_to_float() {
        let add = |l: Json, r: Json| json!({"op":"add","left":l,"right":r});
        assert_eq!(run(add(int(2), int(3)), json!({})), Ok(Value::Int(5)));
        assert_eq!(
            run(add(int(2), json!({"op":"float","value":1.5})), json!({})),
            Ok(Value::Float(3.5))
        );
        assert_eq!(
            run(add(lookup_of("a"), int(1)), json!({"a": 9})),
            Ok(Value::Int(10))
        );
    }

    #[test]
    fn add_refuses_a_non_number_and_an_overflow_with_rubys_words() {
        let add = |l: Json, r: Json| json!({"op":"add","left":l,"right":r});
        assert_eq!(
            run(add(string("a"), int(1)), json!({})),
            Err("addition expects a number, got \"a\"".to_string())
        );
        assert_eq!(
            run(add(lookup_of("a"), int(1)), json!({"a": null})),
            Err("addition expects a number, got nil".to_string())
        );
        assert_eq!(
            run(add(int(1), lookup_of("a")), json!({"a": [1]})),
            Err("addition expects a number, got [1]".to_string())
        );
        assert_eq!(
            run(add(int(i64::MAX), int(1)), json!({})),
            Err(
                "addition overflowed: 9223372036854775807 + 1 does not fit in a 64-bit integer"
                    .to_string()
            )
        );
        let huge = json!({"op":"float","value":1.7e308});
        assert_eq!(
            run(add(huge.clone(), huge), json!({})),
            Err("addition overflowed: 1.7e+308 + 1.7e+308 is not a finite number".to_string())
        );
    }

    #[test]
    fn sub_mul_div_follow_rubys_limits_and_floor_integer_division() {
        let op = |name: &str, l: Json, r: Json| json!({"op":name,"left":l,"right":r});
        assert_eq!(run(op("sub", int(5), int(2)), json!({})), Ok(Value::Int(3)));
        assert_eq!(
            run(
                op("mul", int(6), json!({"op":"float","value":0.5})),
                json!({})
            ),
            Ok(Value::Float(3.0))
        );
        assert_eq!(
            run(op("div", int(-7), int(2)), json!({})),
            Ok(Value::Int(-4))
        );
        assert_eq!(
            run(op("div", int(7), int(-2)), json!({})),
            Ok(Value::Int(-4))
        );
        assert_eq!(
            run(op("div", int(7), int(0)), json!({})),
            Err("divided by 0".to_string())
        );
        assert_eq!(
            run(op("mul", int(i64::MAX), int(2)), json!({})),
            Err("multiplication overflowed: 9223372036854775807 * 2 does not fit in a 64-bit integer".to_string())
        );
        assert_eq!(
            run(op("div", int(i64::MIN), int(-1)), json!({})),
            Err(
                "division overflowed: -9223372036854775808 / -1 does not fit in a 64-bit integer"
                    .to_string()
            )
        );
        assert_eq!(
            run(op("sub", lookup_of("a"), int(1)), json!({"a": null})),
            Err("subtraction expects a number, got nil".to_string())
        );
    }

    #[test]
    fn modulo_floors_like_ruby_for_integers_and_floats() {
        let modulo = |r: Json, d: Json| json!({"op":"modulo","receiver":r,"divisor":d});
        assert_eq!(run(modulo(int(-7), int(3)), json!({})), Ok(Value::Int(2)));
        assert_eq!(run(modulo(int(7), int(-3)), json!({})), Ok(Value::Int(-2)));
        assert_eq!(
            run(modulo(int(i64::MIN), int(-1)), json!({})),
            Ok(Value::Int(0))
        );
        assert_eq!(
            run(modulo(json!({"op":"float","value":5.5}), int(2)), json!({})),
            Ok(Value::Float(1.5))
        );
        assert_eq!(
            run(
                modulo(int(7), json!({"op":"float","value":-2.5})),
                json!({})
            ),
            Ok(Value::Float(-0.5))
        );
        assert_eq!(
            run(
                modulo(json!({"op":"float","value":-1.0}), int(2)),
                json!({})
            ),
            Ok(Value::Float(1.0))
        );
    }

    #[test]
    fn modulo_refuses_a_zero_divisor_and_a_non_number() {
        let modulo = |r: Json, d: Json| json!({"op":"modulo","receiver":r,"divisor":d});
        assert_eq!(
            run(modulo(int(5), int(0)), json!({})),
            Err("divided by 0".to_string())
        );
        assert_eq!(
            run(modulo(int(5), json!({"op":"float","value":0.0})), json!({})),
            Err("divided by 0".to_string())
        );
        assert_eq!(
            run(modulo(string("a"), int(2)), json!({})),
            Err("modulo expects a number, got \"a\"".to_string())
        );
        assert_eq!(
            run(modulo(int(2), lookup_of("d")), json!({"d": null})),
            Err("modulo expects a number, got nil".to_string())
        );
    }

    #[test]
    fn include_tests_list_membership_with_numeric_coercion_and_substrings() {
        let include = |h: Json, n: Json| json!({"op":"include","haystack":h,"needle":n});
        assert_eq!(
            run(
                include(lookup_of("tags"), string("b")),
                json!({"tags": ["a", "b"]})
            ),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(
                include(lookup_of("tags"), string("z")),
                json!({"tags": ["a", "b"]})
            ),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(
                include(lookup_of("n"), json!({"op":"float","value":2.0})),
                json!({"n": [1, 2]})
            ),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(
                include(lookup_of("n"), lookup_of("m")),
                json!({"n": [1, null], "m": null})
            ),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(
                include(lookup_of("s"), string("ell")),
                json!({"s": "hello"})
            ),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(include(lookup_of("s"), string("")), json!({"s": "hello"})),
            Ok(Value::Bool(true))
        );
    }

    #[test]
    fn include_on_anything_but_a_list_or_string_is_false_and_a_string_needs_a_string() {
        let include = |h: Json, n: Json| json!({"op":"include","haystack":h,"needle":n});
        assert_eq!(
            run(include(lookup_of("s"), string("a")), json!({"s": null})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(include(lookup_of("s"), string("a")), json!({"s": 5})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(include(lookup_of("s"), int(1)), json!({"s": "abc"})),
            Err("no implicit conversion of Integer into String".to_string())
        );
        assert_eq!(
            run(
                include(lookup_of("s"), lookup_of("n")),
                json!({"s": "abc", "n": null})
            ),
            Err("no implicit conversion of nil into String".to_string())
        );
    }

    #[test]
    fn array_literals_evaluate_each_element_and_compose_with_first_last_and_include() {
        let array = json!({"op":"array","elements":[int(1), json!({"op":"float","value":2.5}), string("a"), json!({"op":"nil"})]});
        assert_eq!(
            run(array.clone(), json!({})),
            Ok(Value::Array(vec![
                Value::Int(1),
                Value::Float(2.5),
                Value::Str("a".to_string()),
                Value::Nil
            ]))
        );
        assert_eq!(
            run(call("first", array.clone()), json!({})),
            Ok(Value::Int(1))
        );
        assert_eq!(run(call("last", array), json!({})), Ok(Value::Nil));
        assert_eq!(
            run(json!({"op":"array","elements":[]}), json!({})),
            Ok(Value::Array(vec![]))
        );
    }

    #[test]
    fn matches_regex_reads_ruby_anchors_flags_and_ascii_classes() {
        let matches = |pattern: &str, flags: &str| json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":pattern,"flags":flags});
        assert_eq!(
            run(matches("^b$", ""), json!({"x": "a\nb"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches("\\Ab\\z", ""), json!({"x": "a\nb"})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(matches("a.b", ""), json!({"x": "a\nb"})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(matches("a.b", "m"), json!({"x": "a\nb"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches("A", "i"), json!({"x": "a"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches("\\d", ""), json!({"x": "\u{663}"})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(matches("\\A[\\w.]+\\z", ""), json!({"x": "a.b_c"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches("a b", "x"), json!({"x": "ab"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches("\\Aa\\Z", ""), json!({"x": "a\n"})),
            Ok(Value::Bool(true))
        );
    }

    #[test]
    fn matches_regex_coerces_scalars_and_refuses_the_rest_by_class() {
        let matches = json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":"\\A[0-9.]+\\z","flags":""});
        assert_eq!(
            run(matches.clone(), json!({"x": 12})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches.clone(), json!({"x": 1.5})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(
                json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":"\\A\\z","flags":""}),
                json!({"x": null})
            ),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(matches.clone(), json!({"x": true})),
            Err("match? expects a scalar, got TrueClass".to_string())
        );
        assert_eq!(
            run(matches.clone(), json!({"x": false})),
            Err("match? expects a scalar, got FalseClass".to_string())
        );
        assert_eq!(
            run(matches, json!({"x": [1]})),
            Err("match? expects a scalar, got Array".to_string())
        );
    }

    #[test]
    fn matches_regex_refuses_an_invalid_pattern_by_name() {
        let err = run(
            json!({"op":"matches_regex","receiver":string("a"),"pattern":"(","flags":""}),
            json!({}),
        )
        .unwrap_err();
        assert!(
            err.starts_with("match? given an invalid pattern \"(\" — "),
            "{err}"
        );
    }

    #[test]
    fn block_predicates_aggregate_with_ruby_answers_for_an_empty_list() {
        let block = |mode: &str| {
            json!({"op":"block_predicate","mode":mode,"receiver":lookup_of("seats"),"param":"s",
                "predicate":eq(json!({"op":"lookup","path":["s","taken"]}), json!({"op":"bool","value":false}))})
        };
        let seats = json!({"seats": [{"n": 1, "taken": true}, {"n": 2, "taken": false}]});
        assert_eq!(run(block("any"), seats.clone()), Ok(Value::Bool(true)));
        assert_eq!(run(block("all"), seats.clone()), Ok(Value::Bool(false)));
        assert_eq!(run(block("none"), seats), Ok(Value::Bool(false)));
        let empty = json!({"seats": []});
        assert_eq!(run(block("all"), empty.clone()), Ok(Value::Bool(true)));
        assert_eq!(run(block("any"), empty.clone()), Ok(Value::Bool(false)));
        assert_eq!(run(block("none"), empty), Ok(Value::Bool(true)));
    }

    #[test]
    fn a_block_predicate_evaluates_every_element_so_a_later_error_still_surfaces() {
        // `all?` would stop at the first false in a short-circuit loop; Ruby maps first.
        let ast = json!({"op":"block_predicate","mode":"all","receiver":lookup_of("xs"),"param":"x",
            "predicate":json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":lookup_of("x")})});
        assert_eq!(
            run(ast, json!({"xs": [-1, "a"]})),
            Err("positive? expects a number, got \"a\"".to_string())
        );
    }

    #[test]
    fn a_block_predicate_over_a_non_list_refuses_with_the_mode_named() {
        for (mode, word) in [("all", "all?"), ("any", "any?"), ("none", "none?")] {
            let ast = json!({"op":"block_predicate","mode":mode,"receiver":lookup_of("x"),"param":"y","predicate":{"op":"bool","value":true}});
            assert_eq!(
                run(ast.clone(), json!({"x": 5})),
                Err(format!("{word} expects a list, got 5"))
            );
            assert_eq!(
                run(ast, json!({"x": null})),
                Err(format!("{word} expects a list, got nil"))
            );
        }
    }

    #[test]
    fn the_block_parameter_shadows_a_same_named_field_only_inside_the_block() {
        let ast = json!({"op":"block_predicate","mode":"any","receiver":lookup_of("xs"),"param":"n",
            "predicate":{"op":"and","left":eq(lookup_of("n"), int(2)),"right":eq(lookup_of("m"), int(9))}});
        assert_eq!(
            run(ast.clone(), json!({"xs": [1, 2], "m": 9, "n": 100})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(ast, json!({"xs": [1, 2], "m": 8})),
            Ok(Value::Bool(false))
        );
    }

    #[test]
    fn nested_blocks_see_the_outer_parameter() {
        let inner = json!({"op":"block_predicate","mode":"none","receiver":lookup_of("xs"),"param":"o",
            "predicate":eq(lookup_of("o"), json!({"op":"add","left":lookup_of("s"),"right":int(1)}))});
        let outer = json!({"op":"block_predicate","mode":"any","receiver":lookup_of("xs"),"param":"s","predicate":inner});
        // Every element has a successor except the largest, so `any?` holds.
        assert_eq!(run(outer, json!({"xs": [1, 2, 4]})), Ok(Value::Bool(true)));
    }

    #[test]
    fn an_unbound_name_in_a_block_refuses_as_ruby_does() {
        let ast = json!({"op":"block_predicate","mode":"any","receiver":lookup_of("xs"),"param":"x","predicate":lookup_of("ghost")});
        assert_eq!(
            run(ast, json!({"xs": [1]})),
            Err("cannot resolve \"ghost\" — no such attribute or argument".to_string())
        );
    }

    #[test]
    fn find_answers_the_first_match_projected_through_its_path_and_nil_on_a_miss() {
        let find = |wanted: bool, path: &[&str]| {
            json!({"op":"find","receiver":lookup_of("legs"),"param":"l","path":path,
                "predicate":eq(json!({"op":"lookup","path":["l","open"]}), json!({"op":"bool","value":wanted}))})
        };
        let legs = json!({"legs": [{"to": "A", "open": false}, {"to": "B", "open": true}, {"to": "C", "open": true}]});
        assert_eq!(
            run(find(true, &["to"]), legs.clone()),
            Ok(Value::Str("B".to_string()))
        );
        assert_eq!(run(find(true, &["nope"]), legs.clone()), Ok(Value::Nil));
        assert!(matches!(run(find(true, &[]), legs), Ok(Value::Object(_))));
        assert_eq!(
            run(
                find(true, &["to"]),
                json!({"legs": [{"to": "A", "open": false}]})
            ),
            Ok(Value::Nil)
        );
        assert_eq!(
            run(find(true, &["to"]), json!({"legs": []})),
            Ok(Value::Nil)
        );
    }

    #[test]
    fn find_stops_at_the_first_match_but_refuses_a_non_list() {
        // The second element would raise; `find` never reaches it, as Ruby's `Array#find`.
        let ast = json!({"op":"find","receiver":lookup_of("xs"),"param":"x","path":[],
            "predicate":json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":lookup_of("x")})});
        assert_eq!(run(ast.clone(), json!({"xs": [3, "a"]})), Ok(Value::Int(3)));
        assert_eq!(
            run(ast, json!({"xs": "abc"})),
            Err("find expects a list, got \"abc\"".to_string())
        );
    }

    #[test]
    fn presence_and_assignment_follow_blank_and_nil() {
        let presence =
            |negated: bool| json!({"op":"presence","receiver":lookup_of("x"),"negated":negated});
        let assignment =
            |negated: bool| json!({"op":"assignment","receiver":lookup_of("x"),"negated":negated});
        for (value, present) in [
            (json!(null), false),
            (json!(false), false),
            (json!(""), false),
            (json!([]), false),
            (json!(" "), true),
            (json!(0), true),
            (json!(true), true),
            (json!([0]), true),
        ] {
            assert_eq!(
                run(presence(false), json!({"x": value.clone()})),
                Ok(Value::Bool(present)),
                "present? of {value}"
            );
            assert_eq!(
                run(presence(true), json!({"x": value.clone()})),
                Ok(Value::Bool(!present)),
                "blank? of {value}"
            );
        }
        // `set?` asks only `!nil?`: an assigned empty or false value is set.
        assert_eq!(
            run(assignment(false), json!({"x": ""})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(assignment(false), json!({"x": false})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(assignment(false), json!({"x": null})),
            Ok(Value::Bool(false))
        );
        assert_eq!(
            run(assignment(true), json!({"x": null})),
            Ok(Value::Bool(true))
        );
    }

    #[test]
    fn split_follows_ruby_for_awk_empty_and_literal_separators() {
        let split = |sep: &str| json!({"op":"split","receiver":lookup_of("x"),"separator":sep});
        assert_eq!(
            run(split(" "), json!({"x": "  a b  c "})),
            Ok(strs(&["a", "b", "c"]))
        );
        assert_eq!(run(split(""), json!({"x": "aé"})), Ok(strs(&["a", "é"])));
        assert_eq!(
            run(split(","), json!({"x": "a,b,,"})),
            Ok(strs(&["a", "b"]))
        );
        assert_eq!(run(split(","), json!({"x": ",a"})), Ok(strs(&["", "a"])));
        assert_eq!(run(split(","), json!({"x": ""})), Ok(strs(&[])));
        assert_eq!(
            run(split(","), json!({"x": 5})),
            Err("split expects a string, got 5".to_string())
        );
        assert_eq!(
            run(split(","), json!({"x": null})),
            Err("split expects a string, got nil".to_string())
        );
    }

    #[test]
    fn first_and_last_answer_nil_for_an_empty_list_and_refuse_a_non_list() {
        assert_eq!(
            run(call("first", lookup_of("x")), json!({"x": [7, 8]})),
            Ok(Value::Int(7))
        );
        assert_eq!(
            run(call("last", lookup_of("x")), json!({"x": [7, 8]})),
            Ok(Value::Int(8))
        );
        assert_eq!(
            run(call("first", lookup_of("x")), json!({"x": []})),
            Ok(Value::Nil)
        );
        assert_eq!(
            run(call("last", lookup_of("x")), json!({"x": "abc"})),
            Err("last expects a list, got \"abc\"".to_string())
        );
        assert_eq!(
            run(call("first", lookup_of("x")), json!({"x": null})),
            Err("first expects a list, got nil".to_string())
        );
    }

    #[test]
    fn strip_trims_rubys_whitespace_and_needs_a_string() {
        let strip_of = |side: &str, text: &str| {
            run(
                json!({"op":"strip","receiver":lookup_of("x"),"side":side}),
                json!({"x": text}),
            )
        };
        assert_eq!(strip_of("both", " \t a b \0"), Ok(Value::Str("a b".into())));
        assert_eq!(strip_of("left", "  a "), Ok(Value::Str("a ".into())));
        assert_eq!(strip_of("right", " a  "), Ok(Value::Str(" a".into())));
        assert_eq!(
            strip_of("both", "\u{a0}a"),
            Ok(Value::Str("\u{a0}a".into()))
        );
        assert_eq!(
            run(
                json!({"op":"strip","receiver":lookup_of("x"),"side":"both"}),
                json!({"x": null})
            ),
            Err("strip expects a string, got nil".to_string())
        );
    }

    #[test]
    fn starts_with_and_ends_with_need_a_string() {
        let starts = json!({"op":"starts_with","receiver":lookup_of("x"),"substring":"ab"});
        let ends = json!({"op":"ends_with","receiver":lookup_of("x"),"substring":"bc"});
        assert_eq!(
            run(starts.clone(), json!({"x": "abc"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(
            run(ends.clone(), json!({"x": "abc"})),
            Ok(Value::Bool(true))
        );
        assert_eq!(run(ends, json!({"x": "abd"})), Ok(Value::Bool(false)));
        assert_eq!(
            run(starts.clone(), json!({"x": null})),
            Err("start_with? expects a string, got nil".to_string())
        );
        assert_eq!(
            run(starts, json!({"x": [1]})),
            Err("start_with? expects a string, got [1]".to_string())
        );
    }

    #[test]
    fn a_path_through_a_string_list_or_integer_walks_like_ruby() {
        let path = |segments: &[&str]| json!({"op":"lookup","path":segments});
        // `String#[]` answers the segment when it is a substring.
        assert_eq!(
            run(path(&["x", "foo"]), json!({"x": "abcfoo"})),
            Ok(Value::Str("foo".to_string()))
        );
        assert_eq!(
            run(path(&["x", "nil?"]), json!({"x": "abc"})),
            Ok(Value::Nil)
        );
        assert_eq!(run(path(&["x", "a"]), json!({"x": 1.5})), Ok(Value::Nil));
        assert_eq!(run(path(&["x", "a"]), json!({"x": true})), Ok(Value::Nil));
        assert_eq!(
            run(path(&["x", "a"]), json!({"x": [1]})),
            Err("cannot read \"a\" from [1]".to_string())
        );
        assert_eq!(
            run(path(&["x", "a"]), json!({"x": 5})),
            Err("cannot read \"a\" from 5".to_string())
        );
    }

    #[test]
    fn a_one_field_object_reads_as_its_value_and_a_wider_one_stays_an_object() {
        assert_eq!(
            run(lookup_of("x"), json!({"x": {"value": 7}})),
            Ok(Value::Int(7))
        );
        assert!(matches!(
            run(lookup_of("x"), json!({"x": {"a": 1, "b": 2}})),
            Ok(Value::Object(_))
        ));
        assert_eq!(
            run(
                json!({"op":"lookup","path":["x","b"]}),
                json!({"x": {"a": 1, "b": 2}})
            ),
            Ok(Value::Int(2))
        );
    }

    #[test]
    fn errors_are_worded_as_rubys_describe() {
        assert_eq!(
            run(call("size", lookup_of("x")), json!({"x": 5})),
            Err("size expects a list or string, got 5".to_string())
        );
        assert_eq!(
            run(call("empty", lookup_of("x")), json!({"x": null})),
            Err("empty? expects a list or string, got nil".to_string())
        );
        assert_eq!(
            run(call("to_s", lookup_of("x")), json!({"x": [1, "a"]})),
            Err("to_s expects a scalar, got [1,\"a\"]".to_string())
        );
        assert_eq!(
            run(
                json!({"op":"compare","cmp":{"less_than":true,"equal":false,"negated":false},"left":lookup_of("x"),"right":int(1)}),
                json!({"x": "a"})
            ),
            Err("comparison of String with 1 failed".to_string())
        );
        assert_eq!(
            run(
                json!({"op":"sign_test","cmp":{"less_than":false,"equal":true,"negated":false},"receiver":lookup_of("x")}),
                json!({"x": "a"})
            ),
            Err("zero? expects a number, got \"a\"".to_string())
        );
        assert_eq!(
            run(lookup_of("ghost"), json!({})),
            Err("cannot resolve \"ghost\" — no such attribute or argument".to_string())
        );
    }
}
