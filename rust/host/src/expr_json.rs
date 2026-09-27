//! Host-local JSON port of `rust::kernel::expr::Expr`: `parse` reads every node, `interpret`
//! evaluates only the operators real invariants use and refuses the rest by name.

use serde_json::Value as Json;

/// The `cmp` flags of a comparison node: `<`, `==`, and whether the result is negated.
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

/// One JSON object per node, tagged by `"op"`; field names match the Hash keys
/// `ast_json.rb` emits.
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
    Lookup { path: Vec<String> },
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

/// Parses an invariant's `ast` node into an `Expr`.
///
/// An unrecognized `"op"`, or a malformed shape under a known one, is an `Err`.
pub fn parse(json: &Json) -> Result<Expr, String> {
    let op = json.get("op").and_then(Json::as_str).ok_or_else(|| format!("{json} has no string \"op\" field"))?;

    let field = |name: &str| json.get(name).ok_or_else(|| format!("{op} node has no {name:?} field: {json}"));
    let expr = |name: &str| parse(field(name)?);
    let str_field = |name: &str| -> Result<String, String> {
        field(name)?.as_str().map(str::to_string).ok_or_else(|| format!("{op}'s {name:?} isn't a string: {json}"))
    };
    // `lookup.path` and `find.path` are segment arrays, never dotted strings.
    let path_field = |name: &str| -> Result<Vec<String>, String> {
        field(name)?
            .as_array()
            .ok_or_else(|| format!("{op}'s {name:?} isn't an array: {json}"))?
            .iter()
            .map(|v| v.as_str().map(str::to_string).ok_or_else(|| format!("{op}'s {name:?} has a non-string element: {json}")))
            .collect::<Result<Vec<_>, _>>()
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
        "lookup" => Expr::Lookup { path: path_field("path")? },
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
            path: path_field("path")?,
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

/// The runtime value an `Expr` evaluates to.
///
/// Lists are a single `Array` variant: every field here is already a materialised JSON value.
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
    /// Ruby truthiness: everything but `Nil` and `false`.
    ///
    /// Invariant results are checked for truthiness, not `== true`, as `given`/`ensures` are.
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

/// The value as an `f64` when it is an `Int` or `Float`.
fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Int(i) => Some(*i as f64),
        Value::Float(f) => Some(*f),
        _ => None,
    }
}

/// Numeric-coerces both sides first (so `Int(3) == Float(3.0)`), else compares structurally.
fn values_equal(l: &Value, r: &Value) -> bool {
    match (numeric(l), numeric(r)) {
        (Some(a), Some(b)) => a == b,
        _ => l == r,
    }
}

/// Orders numbers, then strings; any other pairing is an error.
fn less_than(l: &Value, r: &Value) -> Result<bool, String> {
    match (numeric(l), numeric(r)) {
        (Some(a), Some(b)) => Ok(a < b),
        _ => match (l, r) {
            (Value::Str(a), Value::Str(b)) => Ok(a < b),
            _ => Err(format!("comparison of {l:?} with {r:?} failed")),
        },
    }
}

/// ORs `<` and `==`, then negates if the operator says so; `SignTest` reuses it against 0.
fn apply_comparison(op: &Comparison, l: &Value, r: &Value) -> Result<bool, String> {
    let lt = op.less_than && less_than(l, r)?;
    let eq = op.equal && values_equal(l, r);
    Ok(if op.negated { !(lt || eq) } else { lt || eq })
}

/// Stringifies a scalar (`Nil` becomes `""`); an `Array` is an error.
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

/// Evaluates `expr` against a value object's JSON fields.
///
/// Unsupported operators return an `Err` naming them. No command arguments are in scope,
/// so `Lookup` reads `instance` alone.
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
        // Parsed but not interpreted: refused by name, never mis-evaluated.
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

/// Resolves a path: the first segment must exist, later segments resolve to `Nil` once
/// the value stops indexing, as Ruby's `Resolver#walk_path` does. That fallthrough is what
/// makes `!flag.nil?` (`["flag", "nil?"]`) mean "does `flag` exist".
fn lookup(path: &[String], instance: &Json) -> Result<Value, String> {
    let Some((head, rest)) = path.split_first() else {
        return Err(format!("lookup given an empty path (path {path:?})"));
    };
    let mut current = instance
        .get(head)
        .ok_or_else(|| format!("cannot resolve {head:?} — no such field (path {path:?})"))?;
    for segment in rest {
        match current.get(segment) {
            Some(next) => current = next,
            None => return Ok(Value::Nil),
        }
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
        // `cents >= 0`, the shape `AstJson.emit_predicate` builds.
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":true,"equal":false,"negated":true},
            "left":{"op":"lookup","path":["cents"]},"right":{"op":"int","value":0}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(1200))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(0))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("cents", serde_json::json!(-1))), Ok(Value::Bool(false)));
    }

    #[test]
    fn a_compound_and_of_four_comparisons_matches_chess_square_bounds() {
        // `file >= 0 && file <= 7 && rank >= 0 && rank <= 7`, chess.bluebook's `Square`.
        fn cmp(less_than: bool, equal: bool, negated: bool, field: &str, n: i64) -> serde_json::Value {
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

        assert_eq!(interpret(&expr, &field("value", serde_json::json!("Margherita"))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(""))), Ok(Value::Bool(false)));
    }

    #[test]
    fn sign_test_positive_matches_a_real_amount_invariant() {
        // `value.positive?` compiles to NOT(value < 0 or value == 0).
        let ast = serde_json::json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":{"op":"lookup","path":["value"]}});
        let expr = parse(&ast).expect("valid Expr JSON");

        assert_eq!(interpret(&expr, &field("value", serde_json::json!(5))), Ok(Value::Bool(true)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(0))), Ok(Value::Bool(false)));
        assert_eq!(interpret(&expr, &field("value", serde_json::json!(-5))), Ok(Value::Bool(false)));
    }

    #[test]
    fn a_not_yet_supported_operator_refuses_by_name_instead_of_mis_evaluating() {
        let ast = serde_json::json!({"op":"presence","receiver":{"op":"lookup","path":["value"]},"negated":false});
        let expr = parse(&ast).expect("valid Expr JSON");

        let err = interpret(&expr, &field("value", serde_json::json!("x"))).unwrap_err();
        assert!(err.contains("not yet supported"), "{err}");
    }

    #[test]
    fn assignment_parses_structurally_the_same_as_presence_and_is_not_yet_interpreted_either() {
        let ast = serde_json::json!({"op":"assignment","receiver":{"op":"lookup","path":["value"]},"negated":true});
        let expr = parse(&ast).expect("valid Expr JSON");

        let err = interpret(&expr, &field("value", serde_json::json!(null))).unwrap_err();
        assert!(err.contains("not yet supported"), "{err}");
    }

    #[test]
    fn int_and_float_compare_equal_across_kinds_the_same_way_the_kernel_does() {
        let ast = serde_json::json!({"op":"compare","cmp":{"less_than":false,"equal":true,"negated":false},
            "left":{"op":"lookup","path":["cents"]},"right":{"op":"float","value":3.0}});
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
