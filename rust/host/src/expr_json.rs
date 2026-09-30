//! Host-local JSON port of `rust::kernel::expr::Expr`: `parse` reads every node and `interpret`
//! evaluates every one with the Ruby runtime's semantics (`Evaluator`/`Resolver`): the same
//! answers, null handling and error wording, so a value object's invariants mint the same way.

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
/// An `Object` is a multi-field value object, kept as the JSON it arrived as; a one-field
/// object never survives a lookup (see `unwrap_scalar`).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Nil,
    Array(Vec<Value>),
    Object(Json),
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
            Json::Object(_) => Ok(Value::Object(json.clone())),
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

/// An `Int` and a `Float` are equal only when the float is a whole number that is that integer.
fn int_equals_float(i: i64, f: f64) -> bool {
    f.is_finite() && f.fract() == 0.0 && (-9.223_372_036_854_775_808e18..9.223_372_036_854_775_808e18).contains(&f) && f as i64 == i
}

/// Ruby's `==` after `Evaluator.equal?`: numbers compare across kinds, and lists and objects
/// compare element by element with the same rule, so `[1] == [1.0]`.
fn values_equal(l: &Value, r: &Value) -> bool {
    match (l, r) {
        (Value::Int(a), Value::Int(b)) => a == b,
        (Value::Int(i), Value::Float(f)) | (Value::Float(f), Value::Int(i)) => int_equals_float(*i, *f),
        (Value::Float(a), Value::Float(b)) => a == b,
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(x, y)| values_equal(x, y)),
        (Value::Object(Json::Object(a)), Value::Object(Json::Object(b))) => {
            a.len() == b.len()
                && a.iter().all(|(key, x)| match (b.get(key), Value::from_json(x)) {
                    (Some(y), Ok(x)) => Value::from_json(y).is_ok_and(|y| values_equal(&x, &y)),
                    _ => false,
                })
        }
        _ => l == r,
    }
}

/// Orders numbers, then strings; any other pairing is an error worded as Ruby's.
fn less_than(l: &Value, r: &Value) -> Result<bool, String> {
    match (l, r) {
        (Value::Int(a), Value::Int(b)) => Ok(a < b),
        _ => match (numeric(l), numeric(r)) {
            (Some(a), Some(b)) => Ok(a < b),
            _ => match (l, r) {
                (Value::Str(a), Value::Str(b)) => Ok(a < b),
                _ => Err(format!("comparison of {} with {} failed", class_of(l), describe(r))),
            },
        },
    }
}

/// ORs `<` and `==`, then negates if the operator says so; `SignTest` reuses it against 0.
fn apply_comparison(op: &Comparison, l: &Value, r: &Value) -> Result<bool, String> {
    let lt = op.less_than && less_than(l, r)?;
    let eq = op.equal && values_equal(l, r);
    Ok(if op.negated { !(lt || eq) } else { lt || eq })
}

/// Stringifies a scalar as Ruby's `to_s` does (`Nil` becomes `""`); a list or object is an error.
fn to_s(v: &Value) -> Result<String, String> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        Value::Int(i) => Ok(i.to_string()),
        Value::Float(f) => Ok(ruby_float(*f)),
        Value::Bool(b) => Ok(b.to_string()),
        Value::Nil => Ok(String::new()),
        Value::Array(_) | Value::Object(_) => Err(format!("to_s expects a scalar, got {}", describe(v))),
    }
}

/// Ruby's `Float#to_s`: shortest round-trip digits, fixed notation for exponents -4 through 14,
/// `d.ddde+XX` outside that.
fn ruby_float(f: f64) -> String {
    if f.is_nan() {
        return "NaN".to_string();
    }
    if f.is_infinite() {
        return if f < 0.0 { "-Infinity" } else { "Infinity" }.to_string();
    }
    let sign = if f.is_sign_negative() { "-" } else { "" };
    if f == 0.0 {
        return format!("{sign}0.0");
    }
    let scientific = format!("{:e}", f.abs());
    let (mantissa, exponent) = scientific.split_once('e').expect("`{:e}` always has an exponent");
    let exponent: i32 = exponent.parse().expect("`{:e}` exponent is an integer");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    if (-4..15).contains(&exponent) {
        if exponent >= 0 {
            let whole = exponent as usize + 1;
            let (int_part, frac_part) = if digits.len() > whole {
                (digits[..whole].to_string(), digits[whole..].to_string())
            } else {
                (format!("{digits}{}", "0".repeat(whole - digits.len())), "0".to_string())
            };
            format!("{sign}{int_part}.{frac_part}")
        } else {
            format!("{sign}0.{}{digits}", "0".repeat((-exponent - 1) as usize))
        }
    } else {
        let frac = if digits.len() > 1 { &digits[1..] } else { "0" };
        format!("{sign}{}.{frac}e{}{:02}", &digits[..1], if exponent < 0 { '-' } else { '+' }, exponent.abs())
    }
}

/// Ruby's `String#inspect` for a UTF-8 string.
fn ruby_inspect(s: &str) -> String {
    let mut out = String::from("\"");
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{07}' => out.push_str("\\a"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0b}' => out.push_str("\\v"),
            '\u{0c}' => out.push_str("\\f"),
            '\u{1b}' => out.push_str("\\e"),
            '#' if matches!(chars.peek(), Some('{' | '$' | '@')) => out.push_str("\\#"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Ruby's `JSON.generate` for a value: what `Rendering.describe` prints for a list or hash.
fn generate(v: &Value) -> String {
    match v {
        Value::Nil => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Int(i) => i.to_string(),
        Value::Float(f) => ruby_float(*f),
        Value::Str(s) => Json::String(s.clone()).to_string(),
        Value::Array(items) => format!("[{}]", items.iter().map(generate).collect::<Vec<_>>().join(",")),
        Value::Object(json) => json.to_string(),
    }
}

/// Ruby's `Rendering.describe`: a value as an error message names it.
fn describe(v: &Value) -> String {
    match v {
        Value::Nil => "nil".to_string(),
        Value::Str(s) => ruby_inspect(s),
        other => generate(other),
    }
}

/// The Ruby class name an error message gives for a value; `nil` for nil, as `class_of` does.
fn class_of(v: &Value) -> &'static str {
    match v {
        Value::Nil => "nil",
        Value::Int(_) => "Integer",
        Value::Float(_) => "Float",
        Value::Str(_) => "String",
        Value::Bool(true) => "TrueClass",
        Value::Bool(false) => "FalseClass",
        Value::Array(_) => "Array",
        // A value object's own class name is not in the JSON; Hash is the nearest honest answer.
        Value::Object(_) => "Hash",
    }
}

/// Requires an `Int` or `Float`, worded as `Resolver.require_number`.
fn require_number(v: &Value, operation: &str) -> Result<Value, String> {
    match v {
        Value::Int(_) | Value::Float(_) => Ok(v.clone()),
        other => Err(format!("{operation} expects a number, got {}", describe(other))),
    }
}

/// `Resolver.add`: 64-bit integer sums that overflow, and float sums that are not finite, fail.
fn add(left: &Value, right: &Value) -> Result<Value, String> {
    let lhs = require_number(left, "addition")?;
    let rhs = require_number(right, "addition")?;
    if let (Value::Int(a), Value::Int(b)) = (&lhs, &rhs) {
        return a.checked_add(*b).map(Value::Int).ok_or_else(|| format!("addition overflowed: {a} + {b} does not fit in a 64-bit integer"));
    }
    let sum = numeric(&lhs).unwrap_or_default() + numeric(&rhs).unwrap_or_default();
    if sum.is_finite() {
        Ok(Value::Float(sum))
    } else {
        Err(format!("addition overflowed: {} + {} is not a finite number", to_s(&lhs)?, to_s(&rhs)?))
    }
}

/// `Resolver.apply_modulo`: floored like Ruby's `%`, so the result takes the divisor's sign.
fn modulo(receiver: &Value, divisor: &Value) -> Result<Value, String> {
    let receiver = require_number(receiver, "modulo")?;
    let divisor = require_number(divisor, "modulo")?;
    if numeric(&divisor) == Some(0.0) {
        return Err("divided by 0".to_string());
    }
    if let (Value::Int(r), Value::Int(d)) = (&receiver, &divisor) {
        // `i64::MIN % -1` overflows in Rust; Ruby answers 0.
        if *d == -1 {
            return Ok(Value::Int(0));
        }
        let raw = r % d;
        return Ok(Value::Int(if raw != 0 && (raw < 0) != (*d < 0) { raw + d } else { raw }));
    }
    let x = numeric(&receiver).unwrap_or_default();
    let y = numeric(&divisor).unwrap_or_default();
    let remainder = if y.is_infinite() && !x.is_infinite() { x } else { x % y };
    Ok(Value::Float(if y * remainder < 0.0 { remainder + y } else { remainder }))
}

/// `Resolver.blank?`: nil, false, and an empty string, list or object.
///
/// Ruby's version judges a list by its own emptiness, so a non-empty list is present in both
/// hosts, whether or not it is made of pairs.
fn blank(v: &Value) -> bool {
    match v {
        Value::Nil | Value::Bool(false) => true,
        Value::Str(s) => s.is_empty(),
        Value::Array(items) => items.is_empty(),
        Value::Object(json) => json.as_object().is_some_and(|fields| fields.is_empty()),
        _ => false,
    }
}

/// Ruby's `String#split` with a string separator: `" "` splits on runs of whitespace, `""` on
/// characters, anything else on the literal text; trailing empty fields are dropped.
fn split(text: &str, separator: &str) -> Vec<Value> {
    let mut parts: Vec<String> = match separator {
        " " => text.split([' ', '\t', '\n', '\u{0b}', '\u{0c}', '\r']).filter(|p| !p.is_empty()).map(str::to_string).collect(),
        "" => text.chars().map(String::from).collect(),
        sep => text.split(sep).map(str::to_string).collect(),
    };
    while parts.last().is_some_and(String::is_empty) {
        parts.pop();
    }
    parts.into_iter().map(Value::Str).collect()
}

/// Compiles a Ruby `Regexp` source for the `regex` crate.
///
/// Ruby's `\d \w \s \h` are ASCII and its `^ $` are always line anchors, where `regex` reads
/// the classes as Unicode and the anchors as text anchors, so both are rewritten. `m` is
/// Ruby's dot-matches-newline; `\Z` (end, or before a final newline) becomes `\n?\z`.
fn ruby_regex(pattern: &str, flags: &str) -> Result<regex::Regex, String> {
    let mut source = String::new();
    let mut in_class = false;
    let mut class_start = 0;
    let chars: Vec<char> = pattern.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if c == '\\' {
            let Some(&next) = chars.get(index + 1) else {
                source.push(c);
                break;
            };
            index += 2;
            let (positive, negative) = match next.to_ascii_lowercase() {
                'd' => ("0-9", "[^0-9]"),
                'w' => ("A-Za-z0-9_", "[^A-Za-z0-9_]"),
                's' => ("\\x20\\t\\r\\n\\f\\x0B", "[^\\x20\\t\\r\\n\\f\\x0B]"),
                'h' => ("0-9a-fA-F", "[^0-9a-fA-F]"),
                _ => {
                    match next {
                        'Z' if !in_class => source.push_str("(?:\\n?\\z)"),
                        _ => {
                            source.push(c);
                            source.push(next);
                        }
                    }
                    continue;
                }
            };
            match (next.is_ascii_uppercase(), in_class) {
                (false, true) => source.push_str(positive),
                (false, false) => source.push_str(&format!("[{positive}]")),
                (true, _) => source.push_str(negative),
            }
            continue;
        }
        if in_class {
            if c == ']' && index != class_start {
                in_class = false;
            }
        } else if c == '[' {
            in_class = true;
            class_start = index + 1;
            if chars.get(class_start) == Some(&'^') {
                class_start += 1;
            }
        } else if c == '^' || c == '$' {
            source.push_str(if c == '^' { "(?m:^)" } else { "(?m:$)" });
            index += 1;
            continue;
        }
        source.push(c);
        index += 1;
    }

    regex::RegexBuilder::new(&source)
        .case_insensitive(flags.contains('i'))
        .dot_matches_new_line(flags.contains('m'))
        .ignore_whitespace(flags.contains('x'))
        .build()
        .map_err(|e| format!("match? given an invalid pattern {} — {e}", ruby_inspect(pattern)))
}

/// One block parameter bound to its element, innermost first; `attrs` in `Resolver#fetch`.
struct Scope<'a> {
    name: &'a str,
    value: Value,
    outer: Option<&'a Scope<'a>>,
}

impl Scope<'_> {
    fn get(&self, name: &str) -> Option<&Value> {
        if self.name == name {
            Some(&self.value)
        } else {
            self.outer.and_then(|outer| outer.get(name))
        }
    }
}

/// Evaluates `expr` against a value object's JSON fields.
///
/// Every node the Ruby runtime (`Evaluator`/`Resolver`) has is interpreted, with its semantics,
/// null handling and error wording. No command arguments are in scope, so `Lookup` reads
/// `instance` alone, after any enclosing block parameters.
pub fn interpret(expr: &Expr, instance: &Json) -> Result<Value, String> {
    eval(expr, instance, None)
}

fn eval(expr: &Expr, instance: &Json, scope: Option<&Scope>) -> Result<Value, String> {
    let recur = |e: &Expr| eval(e, instance, scope);
    match expr {
        Expr::Int { value } => Ok(Value::Int(*value)),
        Expr::Float { value } => Ok(Value::Float(*value)),
        Expr::Str { value } => Ok(Value::Str(value.clone())),
        Expr::Bool { value } => Ok(Value::Bool(*value)),
        Expr::Nil => Ok(Value::Nil),
        Expr::Array { elements } => Ok(Value::Array(elements.iter().map(recur).collect::<Result<Vec<_>, _>>()?)),
        Expr::Lookup { path } => lookup(path, instance, scope),
        Expr::Or { left, right } => Ok(Value::Bool(recur(left)?.truthy() || recur(right)?.truthy())),
        Expr::And { left, right } => Ok(Value::Bool(recur(left)?.truthy() && recur(right)?.truthy())),
        Expr::Not { expr } => Ok(Value::Bool(!recur(expr)?.truthy())),
        Expr::Compare { cmp, left, right } => Ok(Value::Bool(apply_comparison(cmp, &recur(left)?, &recur(right)?)?)),
        // The needle resolves before the haystack, as `Evaluator.includes?` does.
        Expr::Include { haystack, needle } => {
            let wanted = recur(needle)?;
            match recur(haystack)? {
                Value::Array(items) => Ok(Value::Bool(items.iter().any(|item| values_equal(item, &wanted)))),
                Value::Str(text) => match &wanted {
                    Value::Str(part) => Ok(Value::Bool(text.contains(part.as_str()))),
                    other => Err(format!("no implicit conversion of {} into String", class_of(other))),
                },
                _ => Ok(Value::Bool(false)),
            }
        }
        Expr::Add { left, right } => add(&recur(left)?, &recur(right)?),
        Expr::Modulo { receiver, divisor } => modulo(&recur(receiver)?, &recur(divisor)?),
        Expr::SignTest { cmp, receiver } => {
            let v = recur(receiver)?;
            if numeric(&v).is_none() {
                return Err(format!("{} expects a number, got {}", sign_test_name(cmp), describe(&v)));
            }
            Ok(Value::Bool(apply_comparison(cmp, &v, &Value::Int(0))?))
        }
        Expr::Empty { receiver } => match recur(receiver)? {
            Value::Str(s) => Ok(Value::Bool(s.is_empty())),
            Value::Array(items) => Ok(Value::Bool(items.is_empty())),
            other => Err(format!("empty? expects a list or string, got {}", describe(&other))),
        },
        Expr::Size { receiver } => match recur(receiver)? {
            Value::Str(s) => Ok(Value::Int(s.chars().count() as i64)),
            Value::Array(items) => Ok(Value::Int(items.len() as i64)),
            other => Err(format!("size expects a list or string, got {}", describe(&other))),
        },
        Expr::ToS { receiver } => Ok(Value::Str(to_s(&recur(receiver)?)?)),
        Expr::MatchesRegex { receiver, pattern, flags } => {
            let text = match recur(receiver)? {
                Value::Str(s) => s,
                v @ (Value::Int(_) | Value::Float(_)) => to_s(&v)?,
                Value::Nil => String::new(),
                other => return Err(format!("match? expects a scalar, got {}", class_of(&other))),
            };
            Ok(Value::Bool(ruby_regex(pattern, flags)?.is_match(&text)))
        }
        Expr::Presence { receiver, negated } => Ok(Value::Bool(blank(&recur(receiver)?) == *negated)),
        Expr::Assignment { receiver, negated } => Ok(Value::Bool((recur(receiver)? == Value::Nil) == *negated)),
        Expr::Split { receiver, separator } => match recur(receiver)? {
            Value::Str(text) => Ok(Value::Array(split(&text, separator))),
            other => Err(format!("split expects a string, got {}", describe(&other))),
        },
        Expr::First { receiver } => match recur(receiver)? {
            Value::Array(items) => Ok(items.into_iter().next().unwrap_or(Value::Nil)),
            other => Err(format!("first expects a list, got {}", describe(&other))),
        },
        Expr::Last { receiver } => match recur(receiver)? {
            Value::Array(items) => Ok(items.into_iter().next_back().unwrap_or(Value::Nil)),
            other => Err(format!("last expects a list, got {}", describe(&other))),
        },
        Expr::StartsWith { receiver, substring } => match recur(receiver)? {
            Value::Str(text) => Ok(Value::Bool(text.starts_with(substring.as_str()))),
            other => Err(format!("start_with? expects a string, got {}", describe(&other))),
        },
        Expr::EndsWith { receiver, substring } => match recur(receiver)? {
            Value::Str(text) => Ok(Value::Bool(text.ends_with(substring.as_str()))),
            other => Err(format!("end_with? expects a string, got {}", describe(&other))),
        },
        // Every element is evaluated before aggregating, so an error on any element surfaces as
        // it does in Ruby.
        Expr::BlockPredicate { mode, receiver, param, predicate } => {
            let mode_name = match mode {
                BlockMode::All => "all",
                BlockMode::Any => "any",
                BlockMode::None => "none",
            };
            let items = match recur(receiver)? {
                Value::Array(items) => items,
                other => return Err(format!("{mode_name}? expects a list, got {}", describe(&other))),
            };
            let mut outcomes = Vec::with_capacity(items.len());
            for item in items {
                outcomes.push(bound(param, item, instance, scope, predicate)?.truthy());
            }
            Ok(Value::Bool(match mode {
                BlockMode::All => outcomes.iter().all(|o| *o),
                BlockMode::Any => outcomes.iter().any(|o| *o),
                BlockMode::None => !outcomes.iter().any(|o| *o),
            }))
        }
        // The first accepted element ends the scan; a miss is nil, not an error.
        Expr::Find { receiver, param, predicate, path } => {
            let items = match recur(receiver)? {
                Value::Array(items) => items,
                other => return Err(format!("find expects a list, got {}", describe(&other))),
            };
            for item in items {
                if bound(param, item.clone(), instance, scope, predicate)?.truthy() {
                    return if path.is_empty() { Ok(unwrap_scalar(item)) } else { Ok(unwrap_scalar(walk_path(item, path)?)) };
                }
            }
            Ok(Value::Nil)
        }
    }
}

/// Evaluates a block's `predicate` with `param` bound to `item`, shadowing any same-named field.
fn bound(param: &str, item: Value, instance: &Json, scope: Option<&Scope>, predicate: &Expr) -> Result<Value, String> {
    let inner = Scope { name: param, value: item, outer: scope };
    eval(predicate, instance, Some(&inner))
}

/// The `sign_test` a comparison's flags spell, for the error message: `positive?` is
/// `!(< 0 || == 0)`, `negative?` is `< 0`, `zero?` is `== 0`.
fn sign_test_name(cmp: &Comparison) -> &'static str {
    match (cmp.less_than, cmp.equal) {
        (true, true) => "positive?",
        (true, false) => "negative?",
        _ => "zero?",
    }
}

/// `Resolver.unwrap_scalar`: a one-field value object reads as its one value.
fn unwrap_scalar(v: Value) -> Value {
    let sole = match &v {
        Value::Object(Json::Object(fields)) if fields.len() == 1 => fields.values().next().and_then(|only| Value::from_json(only).ok()),
        _ => None,
    };
    sole.unwrap_or(v)
}

/// `Resolver.walk_path`: each segment indexes the current value. An object yields the field or
/// nil; a string yields the segment when it is a substring (Ruby's `String#[]`), else nil; a
/// list or integer cannot be indexed by name; nil, floats and booleans end the walk in nil.
/// That last fallthrough is what makes `!flag.nil?` (`["flag", "nil?"]`) mean "does `flag` exist".
fn walk_path(start: Value, segments: &[String]) -> Result<Value, String> {
    let mut current = start;
    for segment in segments {
        current = match &current {
            Value::Object(Json::Object(fields)) => match fields.get(segment) {
                Some(next) => Value::from_json(next)?,
                None => Value::Nil,
            },
            Value::Str(text) if text.contains(segment.as_str()) => Value::Str(segment.clone()),
            Value::Str(_) => Value::Nil,
            Value::Array(_) | Value::Int(_) => return Err(format!("cannot read {} from {}", ruby_inspect(segment), describe(&current))),
            _ => return Ok(Value::Nil),
        };
    }
    Ok(current)
}

/// Resolves a path as `Resolver#lookup`: the head is a block parameter (innermost first) or a
/// field of `instance`, and must exist; later segments go through `walk_path`.
fn lookup(path: &[String], instance: &Json, scope: Option<&Scope>) -> Result<Value, String> {
    let Some((head, rest)) = path.split_first() else {
        return Err(format!("lookup given an empty path (path {path:?})"));
    };
    let start = match scope.and_then(|s| s.get(head)) {
        Some(value) => value.clone(),
        None => Value::from_json(
            instance.get(head).ok_or_else(|| format!("cannot resolve {} — no such attribute or argument", ruby_inspect(head)))?,
        )?,
    };
    Ok(unwrap_scalar(walk_path(start, rest)?))
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

    // Expected values below are real Ruby results (`Resolver.resolve` / `Evaluator.call`); the
    // differential spec `spec/rust_host_expr_json_conformance_spec.rb` re-checks them live.
    use serde_json::json;

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

    fn call(op: &str, receiver: Json) -> Json {
        json!({"op":op,"receiver":receiver})
    }

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
        assert_eq!(run(add(int(2), json!({"op":"float","value":1.5})), json!({})), Ok(Value::Float(3.5)));
        assert_eq!(run(add(lookup_of("a"), int(1)), json!({"a": 9})), Ok(Value::Int(10)));
    }

    #[test]
    fn add_refuses_a_non_number_and_an_overflow_with_rubys_words() {
        let add = |l: Json, r: Json| json!({"op":"add","left":l,"right":r});
        assert_eq!(run(add(string("a"), int(1)), json!({})), Err("addition expects a number, got \"a\"".to_string()));
        assert_eq!(run(add(lookup_of("a"), int(1)), json!({"a": null})), Err("addition expects a number, got nil".to_string()));
        assert_eq!(run(add(int(1), lookup_of("a")), json!({"a": [1]})), Err("addition expects a number, got [1]".to_string()));
        assert_eq!(
            run(add(int(i64::MAX), int(1)), json!({})),
            Err("addition overflowed: 9223372036854775807 + 1 does not fit in a 64-bit integer".to_string())
        );
        let huge = json!({"op":"float","value":1.7e308});
        assert_eq!(
            run(add(huge.clone(), huge), json!({})),
            Err("addition overflowed: 1.7e+308 + 1.7e+308 is not a finite number".to_string())
        );
    }

    #[test]
    fn modulo_floors_like_ruby_for_integers_and_floats() {
        let modulo = |r: Json, d: Json| json!({"op":"modulo","receiver":r,"divisor":d});
        assert_eq!(run(modulo(int(-7), int(3)), json!({})), Ok(Value::Int(2)));
        assert_eq!(run(modulo(int(7), int(-3)), json!({})), Ok(Value::Int(-2)));
        assert_eq!(run(modulo(int(i64::MIN), int(-1)), json!({})), Ok(Value::Int(0)));
        assert_eq!(run(modulo(json!({"op":"float","value":5.5}), int(2)), json!({})), Ok(Value::Float(1.5)));
        assert_eq!(run(modulo(int(7), json!({"op":"float","value":-2.5})), json!({})), Ok(Value::Float(-0.5)));
        assert_eq!(run(modulo(json!({"op":"float","value":-1.0}), int(2)), json!({})), Ok(Value::Float(1.0)));
    }

    #[test]
    fn modulo_refuses_a_zero_divisor_and_a_non_number() {
        let modulo = |r: Json, d: Json| json!({"op":"modulo","receiver":r,"divisor":d});
        assert_eq!(run(modulo(int(5), int(0)), json!({})), Err("divided by 0".to_string()));
        assert_eq!(run(modulo(int(5), json!({"op":"float","value":0.0})), json!({})), Err("divided by 0".to_string()));
        assert_eq!(run(modulo(string("a"), int(2)), json!({})), Err("modulo expects a number, got \"a\"".to_string()));
        assert_eq!(run(modulo(int(2), lookup_of("d")), json!({"d": null})), Err("modulo expects a number, got nil".to_string()));
    }

    #[test]
    fn include_tests_list_membership_with_numeric_coercion_and_substrings() {
        let include = |h: Json, n: Json| json!({"op":"include","haystack":h,"needle":n});
        assert_eq!(run(include(lookup_of("tags"), string("b")), json!({"tags": ["a", "b"]})), Ok(Value::Bool(true)));
        assert_eq!(run(include(lookup_of("tags"), string("z")), json!({"tags": ["a", "b"]})), Ok(Value::Bool(false)));
        assert_eq!(run(include(lookup_of("n"), json!({"op":"float","value":2.0})), json!({"n": [1, 2]})), Ok(Value::Bool(true)));
        assert_eq!(run(include(lookup_of("n"), lookup_of("m")), json!({"n": [1, null], "m": null})), Ok(Value::Bool(true)));
        assert_eq!(run(include(lookup_of("s"), string("ell")), json!({"s": "hello"})), Ok(Value::Bool(true)));
        assert_eq!(run(include(lookup_of("s"), string("")), json!({"s": "hello"})), Ok(Value::Bool(true)));
    }

    #[test]
    fn include_on_anything_but_a_list_or_string_is_false_and_a_string_needs_a_string() {
        let include = |h: Json, n: Json| json!({"op":"include","haystack":h,"needle":n});
        assert_eq!(run(include(lookup_of("s"), string("a")), json!({"s": null})), Ok(Value::Bool(false)));
        assert_eq!(run(include(lookup_of("s"), string("a")), json!({"s": 5})), Ok(Value::Bool(false)));
        assert_eq!(run(include(lookup_of("s"), int(1)), json!({"s": "abc"})), Err("no implicit conversion of Integer into String".to_string()));
        assert_eq!(run(include(lookup_of("s"), lookup_of("n")), json!({"s": "abc", "n": null})), Err("no implicit conversion of nil into String".to_string()));
    }

    #[test]
    fn array_literals_evaluate_each_element_and_compose_with_first_last_and_include() {
        let array = json!({"op":"array","elements":[int(1), json!({"op":"float","value":2.5}), string("a"), json!({"op":"nil"})]});
        assert_eq!(
            run(array.clone(), json!({})),
            Ok(Value::Array(vec![Value::Int(1), Value::Float(2.5), Value::Str("a".to_string()), Value::Nil]))
        );
        assert_eq!(run(call("first", array.clone()), json!({})), Ok(Value::Int(1)));
        assert_eq!(run(call("last", array), json!({})), Ok(Value::Nil));
        assert_eq!(run(json!({"op":"array","elements":[]}), json!({})), Ok(Value::Array(vec![])));
    }

    #[test]
    fn matches_regex_reads_ruby_anchors_flags_and_ascii_classes() {
        let matches = |pattern: &str, flags: &str| json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":pattern,"flags":flags});
        assert_eq!(run(matches("^b$", ""), json!({"x": "a\nb"})), Ok(Value::Bool(true)));
        assert_eq!(run(matches("\\Ab\\z", ""), json!({"x": "a\nb"})), Ok(Value::Bool(false)));
        assert_eq!(run(matches("a.b", ""), json!({"x": "a\nb"})), Ok(Value::Bool(false)));
        assert_eq!(run(matches("a.b", "m"), json!({"x": "a\nb"})), Ok(Value::Bool(true)));
        assert_eq!(run(matches("A", "i"), json!({"x": "a"})), Ok(Value::Bool(true)));
        assert_eq!(run(matches("\\d", ""), json!({"x": "\u{663}"})), Ok(Value::Bool(false)));
        assert_eq!(run(matches("\\A[\\w.]+\\z", ""), json!({"x": "a.b_c"})), Ok(Value::Bool(true)));
        assert_eq!(run(matches("a b", "x"), json!({"x": "ab"})), Ok(Value::Bool(true)));
        assert_eq!(run(matches("\\Aa\\Z", ""), json!({"x": "a\n"})), Ok(Value::Bool(true)));
    }

    #[test]
    fn matches_regex_coerces_scalars_and_refuses_the_rest_by_class() {
        let matches = json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":"\\A[0-9.]+\\z","flags":""});
        assert_eq!(run(matches.clone(), json!({"x": 12})), Ok(Value::Bool(true)));
        assert_eq!(run(matches.clone(), json!({"x": 1.5})), Ok(Value::Bool(true)));
        assert_eq!(run(json!({"op":"matches_regex","receiver":lookup_of("x"),"pattern":"\\A\\z","flags":""}), json!({"x": null})), Ok(Value::Bool(true)));
        assert_eq!(run(matches.clone(), json!({"x": true})), Err("match? expects a scalar, got TrueClass".to_string()));
        assert_eq!(run(matches.clone(), json!({"x": false})), Err("match? expects a scalar, got FalseClass".to_string()));
        assert_eq!(run(matches, json!({"x": [1]})), Err("match? expects a scalar, got Array".to_string()));
    }

    #[test]
    fn matches_regex_refuses_an_invalid_pattern_by_name() {
        let err = run(json!({"op":"matches_regex","receiver":string("a"),"pattern":"(","flags":""}), json!({})).unwrap_err();
        assert!(err.starts_with("match? given an invalid pattern \"(\" — "), "{err}");
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
        assert_eq!(run(ast, json!({"xs": [-1, "a"]})), Err("positive? expects a number, got \"a\"".to_string()));
    }

    #[test]
    fn a_block_predicate_over_a_non_list_refuses_with_the_mode_named() {
        for (mode, word) in [("all", "all?"), ("any", "any?"), ("none", "none?")] {
            let ast = json!({"op":"block_predicate","mode":mode,"receiver":lookup_of("x"),"param":"y","predicate":{"op":"bool","value":true}});
            assert_eq!(run(ast.clone(), json!({"x": 5})), Err(format!("{word} expects a list, got 5")));
            assert_eq!(run(ast, json!({"x": null})), Err(format!("{word} expects a list, got nil")));
        }
    }

    #[test]
    fn the_block_parameter_shadows_a_same_named_field_only_inside_the_block() {
        let ast = json!({"op":"block_predicate","mode":"any","receiver":lookup_of("xs"),"param":"n",
            "predicate":{"op":"and","left":eq(lookup_of("n"), int(2)),"right":eq(lookup_of("m"), int(9))}});
        assert_eq!(run(ast.clone(), json!({"xs": [1, 2], "m": 9, "n": 100})), Ok(Value::Bool(true)));
        assert_eq!(run(ast, json!({"xs": [1, 2], "m": 8})), Ok(Value::Bool(false)));
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
        assert_eq!(run(ast, json!({"xs": [1]})), Err("cannot resolve \"ghost\" — no such attribute or argument".to_string()));
    }

    #[test]
    fn find_answers_the_first_match_projected_through_its_path_and_nil_on_a_miss() {
        let find = |wanted: bool, path: &[&str]| {
            json!({"op":"find","receiver":lookup_of("legs"),"param":"l","path":path,
                "predicate":eq(json!({"op":"lookup","path":["l","open"]}), json!({"op":"bool","value":wanted}))})
        };
        let legs = json!({"legs": [{"to": "A", "open": false}, {"to": "B", "open": true}, {"to": "C", "open": true}]});
        assert_eq!(run(find(true, &["to"]), legs.clone()), Ok(Value::Str("B".to_string())));
        assert_eq!(run(find(true, &["nope"]), legs.clone()), Ok(Value::Nil));
        assert!(matches!(run(find(true, &[]), legs.clone()), Ok(Value::Object(_))));
        assert_eq!(run(find(true, &["to"]), json!({"legs": [{"to": "A", "open": false}]})), Ok(Value::Nil));
        assert_eq!(run(find(true, &["to"]), json!({"legs": []})), Ok(Value::Nil));
    }

    #[test]
    fn find_stops_at_the_first_match_but_refuses_a_non_list() {
        // The second element would raise; `find` never reaches it, as Ruby's `Array#find`.
        let ast = json!({"op":"find","receiver":lookup_of("xs"),"param":"x","path":[],
            "predicate":json!({"op":"sign_test","cmp":{"less_than":true,"equal":true,"negated":true},"receiver":lookup_of("x")})});
        assert_eq!(run(ast.clone(), json!({"xs": [3, "a"]})), Ok(Value::Int(3)));
        assert_eq!(run(ast, json!({"xs": "abc"})), Err("find expects a list, got \"abc\"".to_string()));
    }

    #[test]
    fn presence_and_assignment_follow_blank_and_nil() {
        let presence = |negated: bool| json!({"op":"presence","receiver":lookup_of("x"),"negated":negated});
        let assignment = |negated: bool| json!({"op":"assignment","receiver":lookup_of("x"),"negated":negated});
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
            assert_eq!(run(presence(false), json!({"x": value.clone()})), Ok(Value::Bool(present)), "present? of {value}");
            assert_eq!(run(presence(true), json!({"x": value.clone()})), Ok(Value::Bool(!present)), "blank? of {value}");
        }
        // `set?` asks only `!nil?`: an assigned empty or false value is set.
        assert_eq!(run(assignment(false), json!({"x": ""})), Ok(Value::Bool(true)));
        assert_eq!(run(assignment(false), json!({"x": false})), Ok(Value::Bool(true)));
        assert_eq!(run(assignment(false), json!({"x": null})), Ok(Value::Bool(false)));
        assert_eq!(run(assignment(true), json!({"x": null})), Ok(Value::Bool(true)));
    }

    #[test]
    fn split_follows_ruby_for_awk_empty_and_literal_separators() {
        let split = |sep: &str| json!({"op":"split","receiver":lookup_of("x"),"separator":sep});
        assert_eq!(run(split(" "), json!({"x": "  a b  c "})), Ok(strs(&["a", "b", "c"])));
        assert_eq!(run(split(""), json!({"x": "aé"})), Ok(strs(&["a", "é"])));
        assert_eq!(run(split(","), json!({"x": "a,b,,"})), Ok(strs(&["a", "b"])));
        assert_eq!(run(split(","), json!({"x": ",a"})), Ok(strs(&["", "a"])));
        assert_eq!(run(split(","), json!({"x": ""})), Ok(strs(&[])));
        assert_eq!(run(split(","), json!({"x": 5})), Err("split expects a string, got 5".to_string()));
        assert_eq!(run(split(","), json!({"x": null})), Err("split expects a string, got nil".to_string()));
    }

    #[test]
    fn first_and_last_answer_nil_for_an_empty_list_and_refuse_a_non_list() {
        assert_eq!(run(call("first", lookup_of("x")), json!({"x": [7, 8]})), Ok(Value::Int(7)));
        assert_eq!(run(call("last", lookup_of("x")), json!({"x": [7, 8]})), Ok(Value::Int(8)));
        assert_eq!(run(call("first", lookup_of("x")), json!({"x": []})), Ok(Value::Nil));
        assert_eq!(run(call("last", lookup_of("x")), json!({"x": "abc"})), Err("last expects a list, got \"abc\"".to_string()));
        assert_eq!(run(call("first", lookup_of("x")), json!({"x": null})), Err("first expects a list, got nil".to_string()));
    }

    #[test]
    fn starts_with_and_ends_with_need_a_string() {
        let starts = json!({"op":"starts_with","receiver":lookup_of("x"),"substring":"ab"});
        let ends = json!({"op":"ends_with","receiver":lookup_of("x"),"substring":"bc"});
        assert_eq!(run(starts.clone(), json!({"x": "abc"})), Ok(Value::Bool(true)));
        assert_eq!(run(ends.clone(), json!({"x": "abc"})), Ok(Value::Bool(true)));
        assert_eq!(run(ends, json!({"x": "abd"})), Ok(Value::Bool(false)));
        assert_eq!(run(starts.clone(), json!({"x": null})), Err("start_with? expects a string, got nil".to_string()));
        assert_eq!(run(starts, json!({"x": [1]})), Err("start_with? expects a string, got [1]".to_string()));
    }

    #[test]
    fn a_path_through_a_string_list_or_integer_walks_like_ruby() {
        let path = |segments: &[&str]| json!({"op":"lookup","path":segments});
        // `String#[]` answers the segment when it is a substring.
        assert_eq!(run(path(&["x", "foo"]), json!({"x": "abcfoo"})), Ok(Value::Str("foo".to_string())));
        assert_eq!(run(path(&["x", "nil?"]), json!({"x": "abc"})), Ok(Value::Nil));
        assert_eq!(run(path(&["x", "a"]), json!({"x": 1.5})), Ok(Value::Nil));
        assert_eq!(run(path(&["x", "a"]), json!({"x": true})), Ok(Value::Nil));
        assert_eq!(run(path(&["x", "a"]), json!({"x": [1]})), Err("cannot read \"a\" from [1]".to_string()));
        assert_eq!(run(path(&["x", "a"]), json!({"x": 5})), Err("cannot read \"a\" from 5".to_string()));
    }

    #[test]
    fn a_one_field_object_reads_as_its_value_and_a_wider_one_stays_an_object() {
        assert_eq!(run(lookup_of("x"), json!({"x": {"value": 7}})), Ok(Value::Int(7)));
        assert!(matches!(run(lookup_of("x"), json!({"x": {"a": 1, "b": 2}})), Ok(Value::Object(_))));
        assert_eq!(run(json!({"op":"lookup","path":["x","b"]}), json!({"x": {"a": 1, "b": 2}})), Ok(Value::Int(2)));
    }

    #[test]
    fn errors_are_worded_as_rubys_describe() {
        assert_eq!(run(call("size", lookup_of("x")), json!({"x": 5})), Err("size expects a list or string, got 5".to_string()));
        assert_eq!(run(call("empty", lookup_of("x")), json!({"x": null})), Err("empty? expects a list or string, got nil".to_string()));
        assert_eq!(run(call("to_s", lookup_of("x")), json!({"x": [1, "a"]})), Err("to_s expects a scalar, got [1,\"a\"]".to_string()));
        assert_eq!(
            run(json!({"op":"compare","cmp":{"less_than":true,"equal":false,"negated":false},"left":lookup_of("x"),"right":int(1)}), json!({"x": "a"})),
            Err("comparison of String with 1 failed".to_string())
        );
        assert_eq!(
            run(json!({"op":"sign_test","cmp":{"less_than":false,"equal":true,"negated":false},"receiver":lookup_of("x")}), json!({"x": "a"})),
            Err("zero? expects a number, got \"a\"".to_string())
        );
        assert_eq!(run(lookup_of("ghost"), json!({})), Err("cannot resolve \"ghost\" — no such attribute or argument".to_string()));
    }

    #[test]
    fn floats_print_as_ruby_prints_them() {
        for (f, text) in [
            (3.0, "3.0"),
            (0.5, "0.5"),
            (-0.0, "-0.0"),
            (100000000000000.0, "100000000000000.0"),
            (999999999999999.9, "999999999999999.9"),
            (1e15, "1.0e+15"),
            (1.5e15, "1.5e+15"),
            (1e20, "1.0e+20"),
            (0.0001, "0.0001"),
            (0.00001, "1.0e-05"),
            (1.5e-7, "1.5e-07"),
            (123456789.123456789, "123456789.12345679"),
        ] {
            assert_eq!(ruby_float(f), text);
            assert_eq!(run(call("to_s", lookup_of("x")), json!({"x": f})), Ok(Value::Str(text.to_string())));
        }
    }

    #[test]
    fn strings_inspect_as_ruby_inspects_them() {
        assert_eq!(ruby_inspect("a\"b\\c\n\u{1}#{x}\u{7f}é"), "\"a\\\"b\\\\c\\n\\u0001\\#{x}\\u007Fé\"");
    }

    #[test]
    fn equality_compares_nested_numbers_across_kinds_like_ruby() {
        assert!(values_equal(&Value::Array(vec![Value::Int(1)]), &Value::Array(vec![Value::Float(1.0)])));
        assert!(!values_equal(&Value::Int(9_007_199_254_740_993), &Value::Float(9_007_199_254_740_992.0)));
        assert!(values_equal(&Value::Int(3), &Value::Float(3.0)));
        assert!(!values_equal(&Value::Int(3), &Value::Float(3.5)));
    }
}
