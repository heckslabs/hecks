// A HOST-LOCAL, JSON-BACKED PORT of `rust::kernel::expr::Expr` — see
// `reference_validate.rs`'s own header for why this exists at all
// (a value object's own `invariant` predicate, checked at mint-time
// audit, with no kernel crate this binary is allowed to link against).
// `lib/hecks/bluebook/expression/ast_json.rb`'s own header is the Ruby
// side of the SAME port — read that file first; this is its mirror.
//
// PARSED FROM `&serde_json::Value` BY HAND, NOT `#[derive(Deserialize)]`
// — matching this crate's own established, exceptionless idiom
// (`reference_validate.rs`/`ir.rs`/every other file here reads `ir.json`
// dynamically via `serde_json::Value`, never a derived struct; grepping
// this whole crate for `derive(Deserialize)` finds nothing) rather than
// adding `serde`'s `derive` feature as this file's own one-off
// dependency for a shape every sibling file already knows how to read
// the plain way.
//
// STRUCTURALLY COMPLETE, NARROWLY INTERPRETED — a real, deliberate split,
// not an oversight:
//
// - `parse`, below, accepts EVERY node the real grammar admits (all 28
//   `rust::kernel::expr::Expr` variants), because `AstJson` on the Ruby
//   side emits ALL of them for ANY value-object invariant an author
//   writes — refusing to even PARSE an unfamiliar shape would turn
//   "this operator isn't checked yet" into "this domain's own ir.json is
//   malformed," a strictly worse failure.
//
// - `interpret`, below, is COMPLETE for exactly the operators a full
//   corpus survey found any real value-object invariant actually using
//   today (`Or`/`And`/`Not`, `Compare`, `SignTest`, `Empty`/`Size`,
//   `ToS`, plus the literal/`Lookup` leaves every expression needs) —
//   the identical algebra `rust::kernel::expression_operators::{logical,
//   comparison, sign_test, sized, to_string}` already implement, ported
//   by reading those files directly rather than re-derived from
//   scratch, since this crate cannot import them. Every OTHER variant
//   (`Include`, `Add`, `Modulo`, `BlockPredicate`, `Find`, `Array`,
//   `MatchesRegex`, `Presence`, `Assignment`, `Split`, `StartsWith`,
//   `EndsWith`, `First`, `Last`) is a REAL, deliberate boundary, not a
//   silent gap: `interpret` refuses them by name, cleanly, the same
//   "unresolved, never guessed" discipline `reference_validate.rs`'s
//   own unrecognized-type-name handling already holds to — an author
//   who writes a value-object invariant using one of these gets a clear, loud audit
//   failure naming exactly which operator isn't checked yet, never a
//   silently-skipped or silently-wrong evaluation. Porting the full
//   11-file operator surface (enumeration's own block-predicate
//   machinery most of all) against zero real corpus examples to validate
//   the port against would be exactly the "invented generality with no
//   real backing" this codebase's own comments elsewhere warn against
//   (`checkout.rs`'s own header, same reasoning one boundary over) —
//   grow this the day a real value-object invariant actually needs one
//   of them, against that real example, not before.

use serde_json::Value as Json;

#[derive(Debug, Clone, Copy)]
pub struct Comparison {
    pub less_than: bool,
    pub equal: bool,
    pub negated: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum BlockMode {
    All,
    Any,
    None,
}

/// One JSON object per node, tagged by `"op"` — the exact wire shape
/// `lib/hecks/bluebook/expression/ast_json.rb`'s own `emit_bool`/
/// `emit_resolver` build. Field names match that file's Hash keys 1:1
/// (`cmp` for a `Comparison`, `receiver`/`left`/`right`/`expr` for
/// nested nodes, matching each operator's own Ruby-side vocabulary).
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum Expr {
    Or { left: Box<Expr>, right: Box<Expr> },
    And { left: Box<Expr>, right: Box<Expr> },
    Not { expr: Box<Expr> },
    Compare { cmp: Comparison, left: Box<Expr>, right: Box<Expr> },
    Include { haystack: Box<Expr>, needle: Box<Expr> },
    Int { value: i64 },
    Float { value: f64 },
    Str { value: String },
    Bool { value: bool },
    Nil,
    Add { left: Box<Expr>, right: Box<Expr> },
    SignTest { cmp: Comparison, receiver: Box<Expr> },
    Empty { receiver: Box<Expr> },
    ToS { receiver: Box<Expr> },
    Modulo { receiver: Box<Expr>, divisor: Box<Expr> },
    Size { receiver: Box<Expr> },
    Lookup { path: String },
    BlockPredicate { mode: BlockMode, receiver: Box<Expr>, param: String, predicate: Box<Expr> },
    Find { receiver: Box<Expr>, param: String, predicate: Box<Expr>, path: Vec<String> },
    Array { elements: Vec<Expr> },
    MatchesRegex { receiver: Box<Expr>, pattern: String, flags: String },
    Presence { receiver: Box<Expr>, negated: bool },
    Assignment { receiver: Box<Expr>, negated: bool },
    Split { receiver: Box<Expr>, separator: String },
    StartsWith { receiver: Box<Expr>, substring: String },
    EndsWith { receiver: Box<Expr>, substring: String },
    First { receiver: Box<Expr> },
    Last { receiver: Box<Expr> },
}

/// `json["ast"]`, straight off an `invariant`'s own IR node — every real
/// arm named below, an unrecognized `"op"` (or a malformed shape under a
/// recognized one) refused BY NAME rather than silently defaulted, the
/// same discipline `reference_validate.rs`'s own header holds every
/// other check here to.
pub fn parse(json: &Json) -> Result<Expr, String> {
    let op = json.get("op").and_then(Json::as_str).ok_or_else(|| format!("{json} has no string \"op\" field"))?;

    let field = |name: &str| json.get(name).ok_or_else(|| format!("{op} node has no {name:?} field: {json}"));
    let expr = |name: &str| parse(field(name)?);
    let str_field = |name: &str| -> Result<String, String> {
        field(name)?.as_str().map(str::to_string).ok_or_else(|| format!("{op}'s {name:?} isn't a string: {json}"))
    };
    let comparison = || -> Result<Comparison, String> {
        let cmp = field("cmp")?;
        Ok(Comparison {
            less_than: cmp.get("less_than").and_then(Json::as_bool).ok_or_else(|| format!("{op}'s cmp has no less_than: {json}"))?,
            equal: cmp.get("equal").and_then(Json::as_bool).ok_or_else(|| format!("{op}'s cmp has no equal: {json}"))?,
            negated: cmp.get("negated").and_then(Json::as_bool).ok_or_else(|| format!("{op}'s cmp has no negated: {json}"))?,
        })
    };

    Ok(match op {
        "or" => Expr::Or { left: Box::new(expr("left")?), right: Box::new(expr("right")?) },
        "and" => Expr::And { left: Box::new(expr("left")?), right: Box::new(expr("right")?) },
        "not" => Expr::Not { expr: Box::new(expr("expr")?) },
        "compare" => Expr::Compare { cmp: comparison()?, left: Box::new(expr("left")?), right: Box::new(expr("right")?) },
        "include" => Expr::Include { haystack: Box::new(expr("haystack")?), needle: Box::new(expr("needle")?) },
        "int" => Expr::Int { value: field("value")?.as_i64().ok_or_else(|| format!("int's value isn't an integer: {json}"))? },
        "float" => Expr::Float { value: field("value")?.as_f64().ok_or_else(|| format!("float's value isn't a number: {json}"))? },
        "str" => Expr::Str { value: str_field("value")? },
        "bool" => Expr::Bool { value: field("value")?.as_bool().ok_or_else(|| format!("bool's value isn't a boolean: {json}"))? },
        "nil" => Expr::Nil,
        "add" => Expr::Add { left: Box::new(expr("left")?), right: Box::new(expr("right")?) },
        "sign_test" => Expr::SignTest { cmp: comparison()?, receiver: Box::new(expr("receiver")?) },
        "empty" => Expr::Empty { receiver: Box::new(expr("receiver")?) },
        "to_s" => Expr::ToS { receiver: Box::new(expr("receiver")?) },
        "modulo" => Expr::Modulo { receiver: Box::new(expr("receiver")?), divisor: Box::new(expr("divisor")?) },
        "size" => Expr::Size { receiver: Box::new(expr("receiver")?) },
        "lookup" => Expr::Lookup { path: str_field("path")? },
        "block_predicate" => Expr::BlockPredicate {
            mode: match str_field("mode")?.as_str() {
                "all" => BlockMode::All,
                "any" => BlockMode::Any,
                "none" => BlockMode::None,
                other => return Err(format!("block_predicate's mode {other:?} is none of all/any/none: {json}")),
            },
            receiver: Box::new(expr("receiver")?),
            param: str_field("param")?,
            predicate: Box::new(expr("predicate")?),
        },
        "find" => Expr::Find {
            receiver: Box::new(expr("receiver")?),
            param: str_field("param")?,
            predicate: Box::new(expr("predicate")?),
            path: field("path")?
                .as_array()
                .ok_or_else(|| format!("find's path isn't an array: {json}"))?
                .iter()
                .map(|v| v.as_str().map(str::to_string).ok_or_else(|| format!("find's path has a non-string element: {json}")))
                .collect::<Result<Vec<_>, _>>()?,
        },
        "array" => Expr::Array {
            elements: field("elements")?
                .as_array()
                .ok_or_else(|| format!("array's elements isn't an array: {json}"))?
                .iter()
                .map(parse)
                .collect::<Result<Vec<_>, _>>()?,
        },
        "matches_regex" => Expr::MatchesRegex { receiver: Box::new(expr("receiver")?), pattern: str_field("pattern")?, flags: str_field("flags")? },
        "presence" => Expr::Presence {
            receiver: Box::new(expr("receiver")?),
            negated: field("negated")?.as_bool().ok_or_else(|| format!("presence's negated isn't a boolean: {json}"))?,
        },
        "assignment" => Expr::Assignment {
            receiver: Box::new(expr("receiver")?),
            negated: field("negated")?.as_bool().ok_or_else(|| format!("assignment's negated isn't a boolean: {json}"))?,
        },
        "split" => Expr::Split { receiver: Box::new(expr("receiver")?), separator: str_field("separator")? },
        "starts_with" => Expr::StartsWith { receiver: Box::new(expr("receiver")?), substring: str_field("substring")? },
        "ends_with" => Expr::EndsWith { receiver: Box::new(expr("receiver")?), substring: str_field("substring")? },
        "first" => Expr::First { receiver: Box::new(expr("receiver")?) },
        "last" => Expr::Last { receiver: Box::new(expr("receiver")?) },
        other => return Err(format!("unrecognized expression op {other:?}: {json}")),
    })
}

/// The runtime value an `Expr` evaluates to — mirrors `rust::kernel::
/// expr::Value` (`Int`/`Float`/`Str`/`Bool`/`Nil`), collapsed to ONE
/// list shape (`Array`) rather than that file's own `List(usize)`/
/// `Array(Vec<Value>)` split: that split exists there ONLY because a
/// compiled kernel field's own length and its own elements are two
/// separately-reachable things (`Fielded::field` vs `::items`) — here,
/// every "field" IS already a fully-materialised `serde_json::Value`,
/// so a list's own elements are always already in hand; there is no
/// length-only reading to keep separate.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Nil,
    Array(Vec<Value>),
}

impl Value {
    /// Ruby's `Evaluator.truthy?` — `rust::kernel::expr::Value::truthy`,
    /// read directly. `pub(crate)`, not private — `reference_validate.rs`'s
    /// own `check_invariants` needs the identical reading of an
    /// invariant's own final result (a value object's `invariant("...")
    /// { predicate }` is checked for TRUTHINESS, not strict `== true`,
    /// the same way a command's own `given`/`ensures` already is).
    pub(crate) fn truthy(&self) -> bool {
        !matches!(self, Value::Nil | Value::Bool(false))
    }

    fn from_json(json: &Json) -> Result<Value, String> {
        match json {
            Json::Null => Ok(Value::Nil),
            Json::Bool(b) => Ok(Value::Bool(*b)),
            Json::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Ok(Value::Int(i))
                } else if let Some(f) = n.as_f64() {
                    Ok(Value::Float(f))
                } else {
                    Err(format!("{n} is a number this interpreter cannot represent"))
                }
            }
            Json::String(s) => Ok(Value::Str(s.clone())),
            Json::Array(items) => Ok(Value::Array(items.iter().map(Value::from_json).collect::<Result<Vec<_>, _>>()?)),
            Json::Object(_) => Err("cannot use a nested object as a scalar value directly".to_string()),
        }
    }
}

/// `Resolver.numeric` (resolver.rb) — `rust::kernel::attribute_shapes::
/// scalar::numeric`, read directly.
fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Int(i) => Some(*i as f64),
        Value::Float(f) => Some(*f),
        _ => None,
    }
}

/// `comparison::values_equal`, read directly: numeric-coerce both sides
/// first (so `Int(3) == Float(3.0)`), else compare structurally.
fn values_equal(l: &Value, r: &Value) -> bool {
    match (numeric(l), numeric(r)) {
        (Some(a), Some(b)) => a == b,
        _ => l == r,
    }
}

/// `comparison::less_than`, read directly: numeric first, string second,
/// refuse anything else the same way that file's own trailing arm does.
fn less_than(l: &Value, r: &Value) -> Result<bool, String> {
    match (numeric(l), numeric(r)) {
        (Some(a), Some(b)) => Ok(a < b),
        _ => match (l, r) {
            (Value::Str(a), Value::Str(b)) => Ok(a < b),
            _ => Err(format!("comparison of {l:?} with {r:?} failed")),
        },
    }
}

/// `comparison::apply`, read directly: OR the two primitives together,
/// negate if the operator says to. `sign_test` below reuses this against
/// a literal `Value::Int(0)`, the identical reuse the kernel's own
/// `sign_test.rs` makes of `comparison::apply`.
fn apply_comparison(op: &Comparison, l: &Value, r: &Value) -> Result<bool, String> {
    let lt = op.less_than && less_than(l, r)?;
    let eq = op.equal && values_equal(l, r);
    Ok(if op.negated { !(lt || eq) } else { lt || eq })
}

/// `scalar::to_s`, read directly — `Int`/`Float`/`Bool`/`Str` each
/// stringify; `Nil` stringifies to `""` (`attribute_shapes::optional::
/// to_s`, read directly). `Array` refuses, the same explicit "no real
/// corpus predicate calls `.to_s` on a list" refusal `to_string.rs`'s
/// own trailing arm gives.
fn to_s(v: &Value) -> Result<String, String> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        Value::Int(i) => Ok(i.to_string()),
        Value::Float(f) => Ok(f.to_string()),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Nil => Ok(String::new()),
        Value::Array(_) => Err(format!("to_s expects a scalar, got {v:?}")),
    }
}

/// THE ONE INTERPRETER — see this file's own header for exactly which
/// operators below are real and which cleanly refuse. `instance` is the
/// value object's own already-materialised JSON fields — a value-object
/// invariant is always checked with NO command arguments in scope
/// (`rust::kernel::expr::NoFields`'s own header: "a value object
/// checking its own invariants... only the value object's own fields as
/// `state`"), so there is no args-then-instance precedence to thread
/// here the way the kernel's own `EvalContext` needs for a command's
/// `given`/`ensures` — one flat lookup surface is the whole, correct
/// story for this specific caller.
pub fn interpret(expr: &Expr, instance: &Json) -> Result<Value, String> {
    match expr {
        Expr::Int { value } => Ok(Value::Int(*value)),
        Expr::Float { value } => Ok(Value::Float(*value)),
        Expr::Str { value } => Ok(Value::Str(value.clone())),
        Expr::Bool { value } => Ok(Value::Bool(*value)),
        Expr::Nil => Ok(Value::Nil),
        Expr::Lookup { path } => lookup(path, instance),
        Expr::Or { left, right } => Ok(Value::Bool(interpret(left, instance)?.truthy() || interpret(right, instance)?.truthy())),
        Expr::And { left, right } => Ok(Value::Bool(interpret(left, instance)?.truthy() && interpret(right, instance)?.truthy())),
        Expr::Not { expr } => Ok(Value::Bool(!interpret(expr, instance)?.truthy())),
        Expr::Compare { cmp, left, right } => {
            Ok(Value::Bool(apply_comparison(cmp, &interpret(left, instance)?, &interpret(right, instance)?)?))
        }
        Expr::SignTest { cmp, receiver } => {
            let v = interpret(receiver, instance)?;
            if numeric(&v).is_none() {
                return Err(format!("sign test expects a number, got {v:?}"));
            }
            Ok(Value::Bool(apply_comparison(cmp, &v, &Value::Int(0))?))
        }
        Expr::Empty { receiver } => match interpret(receiver, instance)? {
            Value::Str(s) => Ok(Value::Bool(s.is_empty())),
            Value::Array(items) => Ok(Value::Bool(items.is_empty())),
            other => Err(format!("empty? expects a list or string, got {other:?}")),
        },
        Expr::Size { receiver } => match interpret(receiver, instance)? {
            Value::Str(s) => Ok(Value::Int(s.chars().count() as i64)),
            Value::Array(items) => Ok(Value::Int(items.len() as i64)),
            other => Err(format!("size expects a list or string, got {other:?}")),
        },
        Expr::ToS { receiver } => Ok(Value::Str(to_s(&interpret(receiver, instance)?)?)),
        // See this file's own header — deliberately not yet interpreted,
        // refused by name rather than silently mis-evaluated or panicking.
        Expr::Include { .. }
        | Expr::Add { .. }
        | Expr::Modulo { .. }
        | Expr::BlockPredicate { .. }
        | Expr::Find { .. }
        | Expr::Array { .. }
        | Expr::MatchesRegex { .. }
        | Expr::Presence { .. }
        | Expr::Assignment { .. }
        | Expr::Split { .. }
        | Expr::StartsWith { .. }
        | Expr::EndsWith { .. }
        | Expr::First { .. }
        | Expr::Last { .. } => Err(format!("{expr:?} is not yet supported for value-object invariant checking at mint time")),
    }
}

/// `Resolver#fetch`'s own dotted-path walk, narrowed to what a value-
/// object invariant actually needs: every real corpus example (`cents`,
/// `value`, `file`, `rank`, ...) is a BARE, single-segment lookup
/// against the value object's own top-level fields — no real invariant
/// dots into a nested object. A dotted path still walks segment by
/// segment via plain JSON `.get`, the direct equivalent of `composite::
/// step`, rather than refusing outright — it just has no real corpus
/// caller to prove it against yet.
fn lookup(path: &str, instance: &Json) -> Result<Value, String> {
    let mut current = instance;
    for segment in path.split('.') {
        current = current
            .get(segment)
            .ok_or_else(|| format!("cannot resolve {segment:?} — no such field (path {path:?})"))?;
    }
    Value::from_json(current)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(name: &str, value: Json) -> Json {
        serde_json::json!({ name: value })
    }

    #[test]
    fn cents_gte_zero_holds_for_a_non_negative_amount() {
        // `cents >= 0`, the exact shape `AstJson.emit_predicate` builds —
        // see this file's own smoke test in the Ruby suite for the
        // matching JSON.
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":true,"equal":false,"negated":true},
            "left":{"op":"lookup","path":"cents"},"right":{"op":"int","value":0}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(1200))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(0))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(-1))), Ok(Value::Bool(false)));
    }

    #[test]
    fn a_compound_and_of_four_comparisons_matches_chess_square_bounds() {
        // `file >= 0 && file <= 7 && rank >= 0 && rank <= 7`, real corpus
        // text (chess.bluebook's own `Square`).
        fn cmp(less_than: bool, equal: bool, negated: bool, field: &str, n: i64) -> serde_json::Value {
            serde_json::json!({"op":"compare","cmp":{"less_than":less_than,"equal":equal,"negated":negated},
                "left":{"op":"lookup","path":field},"right":{"op":"int","value":n}})
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
        // `!value.to_s.empty?`, the most common real corpus shape
        // (PizzaName, CustomerName, ToppingName, ...).
        let ast = serde_json::json!({"op":"not","expr":{"op":"empty","receiver":{"op":"to_s","receiver":{"op":"lookup","path":"value"}}}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("value", serde_json::json!("Margherita"))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(""))), Ok(Value::Bool(false)));
    }

    #[test]
    fn sign_test_positive_matches_a_real_amount_invariant() {
        // `value.positive?` — `{less_than: true, equal: true, negated:
        // true}`, confirmed against the real Ruby emitter directly
        // (`value.positive?` compiles to NOT(value < 0 OR value == 0)).
        let ast = serde_json::json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":{"op":"lookup","path":"value"}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("value", serde_json::json!(5))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(0))), Ok(Value::Bool(false)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(-5))), Ok(Value::Bool(false)));
    }

    #[test]
    fn a_not_yet_supported_operator_refuses_by_name_instead_of_mis_evaluating() {
        let ast = serde_json::json!({"op":"presence","receiver":{"op":"lookup","path":"value"},"negated":false});
        let expr = parse(&ast).expect("valid Expr JSON");

        let err = interpret(&expr, &field("value", serde_json::json!("x"))).unwrap_err();
        assert!(err.contains("not yet supported"), "{err}");
    }

    #[test]
    fn assignment_parses_structurally_the_same_as_presence_and_is_not_yet_interpreted_either() {
        let ast = serde_json::json!({"op":"assignment","receiver":{"op":"lookup","path":"value"},"negated":true});
        let expr = parse(&ast).expect("valid Expr JSON");

        let err = interpret(&expr, &field("value", serde_json::json!(null))).unwrap_err();
        assert!(err.contains("not yet supported"), "{err}");
    }

    #[test]
    fn int_and_float_compare_equal_across_kinds_the_same_way_the_kernel_does() {
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":false,"equal":true,"negated":false},
            "left":{"op":"lookup","path":"cents"},"right":{"op":"float","value":3.0}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(3))), Ok(Value::Bool(true)));
    }

    #[test]
    fn an_unrecognized_op_refuses_to_parse_rather_than_defaulting() {
        let ast = serde_json::json!({"op":"frobnicate"});
        let err = parse(&ast).unwrap_err();
        assert!(err.contains("unrecognized"), "{err}");
    }
}
