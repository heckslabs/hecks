use super::evaluator::{apply, Operator, OPERATORS};
use serde_json::{Map, Value};

pub type State = Map<String, Value>;

pub type Eval<T> = Result<T, String>;

const SIGN_TESTS: [&str; 3] = ["positive?", "negative?", "zero?"];

// The leaf grammar an expression's dotted/arithmetic side parses into. Which
// node a string produces is a pure function of the string, so parse() runs
// once per distinct leaf — folded into Evaluator's own AST_CACHE, since a
// leaf string is a substring of some canonical predicate that only gets
// parsed on that predicate's first evaluation (see evaluator.rs) — and
// interpret() reads state/attrs fresh on every call. Only Lookup, the true
// leaf, ever touches state/attrs.
#[derive(Debug)]
pub(crate) enum ResolverNode {
    IntegerLiteral(i64),
    FloatLiteral(f64),
    StringLiteral(String),
    BoolLiteral(bool),
    NilLiteral,
    Addition(Box<ResolverNode>, Box<ResolverNode>),
    SignTest {
        operator: &'static Operator,
        test: &'static str,
        receiver: Box<ResolverNode>,
    },
    Empty(Box<ResolverNode>),
    ToS(Box<ResolverNode>),
    Modulo(Box<ResolverNode>, Box<ResolverNode>),
    Size(Box<ResolverNode>),
    Lookup(String),
}

pub fn resolve_expr(expr: &str, state: &State, attrs: &State) -> Eval<Value> {
    interpret(&parse(expr), state, attrs)
}

pub(crate) fn parse(expr: &str) -> ResolverNode {
    let expr = expr.trim();

    if let Some(field) = expr.strip_suffix(".length") {
        return ResolverNode::Size(Box::new(parse(field.trim())));
    }

    if let Ok(n) = expr.parse::<i64>() {
        return ResolverNode::IntegerLiteral(n);
    }
    if let Ok(f) = expr.parse::<f64>() {
        return ResolverNode::FloatLiteral(f);
    }
    if is_quoted(expr) {
        return ResolverNode::StringLiteral(expr[1..expr.len() - 1].to_string());
    }
    match expr {
        "true" => return ResolverNode::BoolLiteral(true),
        "false" => return ResolverNode::BoolLiteral(false),
        "nil" | "null" => return ResolverNode::NilLiteral,
        _ => {}
    }

    if let Some((left, right)) = split_addition(expr) {
        return ResolverNode::Addition(Box::new(parse(&left)), Box::new(parse(&right)));
    }

    for test in SIGN_TESTS {
        if let Some(receiver) = expr.strip_suffix(&format!(".{}", test)) {
            return sign_test_node(receiver, test);
        }
    }

    if let Some(receiver) = expr.strip_suffix(".empty?") {
        return ResolverNode::Empty(Box::new(parse(receiver.trim())));
    }

    if let Some(receiver) = expr.strip_suffix(".to_s") {
        return ResolverNode::ToS(Box::new(parse(receiver.trim())));
    }

    if let Some((receiver, argument)) = match_call(expr, ".modulo(") {
        return ResolverNode::Modulo(Box::new(parse(&receiver)), Box::new(parse(&argument)));
    }

    if let Some(receiver) = expr.strip_suffix(".size") {
        return ResolverNode::Size(Box::new(parse(receiver.trim())));
    }

    ResolverNode::Lookup(expr.to_string())
}

fn sign_test_node(receiver: &str, test: &'static str) -> ResolverNode {
    let symbol = sign_test_operator(test);
    let operator = OPERATORS
        .iter()
        .find(|candidate| candidate.symbol == symbol)
        .expect("sign_test_operator names a declared Comparison operator");
    ResolverNode::SignTest {
        operator,
        test,
        receiver: Box::new(parse(receiver)),
    }
}

pub(crate) fn interpret(node: &ResolverNode, state: &State, attrs: &State) -> Eval<Value> {
    match node {
        ResolverNode::IntegerLiteral(n) => Ok(Value::from(*n)),
        ResolverNode::FloatLiteral(f) => Ok(Value::from(*f)),
        ResolverNode::StringLiteral(text) => Ok(Value::String(text.clone())),
        ResolverNode::BoolLiteral(flag) => Ok(Value::Bool(*flag)),
        ResolverNode::NilLiteral => Ok(Value::Null),
        ResolverNode::Addition(left, right) => {
            let left = require_number(&interpret(left, state, attrs)?, "addition")?;
            let right = require_number(&interpret(right, state, attrs)?, "addition")?;
            Ok(Value::from(left + right))
        }
        ResolverNode::SignTest {
            operator,
            test,
            receiver,
        } => {
            let value = interpret(receiver, state, attrs)?;
            let number = numeric_value(&value)
                .ok_or_else(|| format!("{} expects a number, got {}", test, describe(&value)))?;
            Ok(Value::Bool(apply(
                operator,
                &Value::from(number),
                &Value::from(0),
            )?))
        }
        ResolverNode::Empty(receiver) => emptiness_of(&interpret(receiver, state, attrs)?),
        ResolverNode::ToS(receiver) => string_of(&interpret(receiver, state, attrs)?),
        ResolverNode::Modulo(receiver, argument) => {
            let divisor = require_number(&interpret(argument, state, attrs)?, "modulo")?;
            if divisor == 0.0 {
                return Err("divided by 0".to_string());
            }
            let left = require_number(&interpret(receiver, state, attrs)?, "modulo")?;
            Ok(Value::from((left as i64).rem_euclid(divisor as i64)))
        }
        ResolverNode::Size(receiver) => size_of(&interpret(receiver, state, attrs)?),
        ResolverNode::Lookup(path) => lookup(path, state, attrs),
    }
}

fn split_addition(expr: &str) -> Option<(String, String)> {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;

    for (index, character) in expr.char_indices() {
        if let Some(open) = quote {
            if character == open {
                quote = None;
            }
            continue;
        }

        match character {
            '\'' | '"' => quote = Some(character),
            '(' => depth += 1,
            ')' => depth -= 1,
            '+' if depth == 0 => {
                return Some((
                    expr[..index].trim().to_string(),
                    expr[index + 1..].trim().to_string(),
                ));
            }
            _ => {}
        }
    }
    None
}

pub fn is_quoted(expr: &str) -> bool {
    let bytes = expr.as_bytes();
    if bytes.len() < 2 {
        return false;
    }
    let (first, last) = (bytes[0], bytes[bytes.len() - 1]);
    (first == b'"' && last == b'"') || (first == b'\'' && last == b'\'')
}

fn size_of(value: &Value) -> Eval<Value> {
    match value {
        Value::Array(items) => Ok(Value::from(items.len() as i64)),
        Value::String(text) => Ok(Value::from(text.chars().count() as i64)),
        Value::Object(map) => Ok(Value::from(map.len() as i64)),
        other => Err(format!(
            "size expects a list or string, got {}",
            describe(other)
        )),
    }
}

fn emptiness_of(value: &Value) -> Eval<Value> {
    match value {
        Value::Array(items) => Ok(Value::Bool(items.is_empty())),
        Value::String(text) => Ok(Value::Bool(text.is_empty())),
        Value::Object(map) => Ok(Value::Bool(map.is_empty())),
        other => Err(format!(
            "empty? expects a list or string, got {}",
            describe(other)
        )),
    }
}

fn string_of(value: &Value) -> Eval<Value> {
    Ok(Value::String(match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        Value::Bool(flag) => flag.to_string(),
        Value::Number(n) => match n.as_i64() {
            Some(i) => i.to_string(),
            None => format_float(n.as_f64().unwrap_or(0.0)),
        },
        other => return Err(format!("to_s expects a scalar, got {}", describe(other))),
    }))
}

// Which Comparison operator each sign test is sugar for, against the literal
// 0 — declared the same way in Vocabulary::SignTest's compares_via
// (language/bluebook.bluebook) ; spec/vocabulary_conformance_spec holds the
// two tables equal.
fn sign_test_operator(test: &str) -> &'static str {
    match test {
        "positive?" => ">",
        "negative?" => "<",
        _ => "==",
    }
}

pub fn match_call(expr: &str, marker: &str) -> Option<(String, String)> {
    if !expr.ends_with(')') {
        return None;
    }
    let index = expr.rfind(marker)?;
    Some((
        expr[..index].to_string(),
        expr[index + marker.len()..expr.len() - 1].to_string(),
    ))
}

fn lookup(expr: &str, state: &State, attrs: &State) -> Eval<Value> {
    if !expr.contains('.') {
        return fetch(expr, state, attrs);
    }

    let mut segments = expr.split('.');
    let head = segments.next().unwrap_or_default();
    let mut current = fetch(head, state, attrs)?;

    for segment in segments {
        current = match current {
            Value::Object(map) => map.get(segment).cloned().unwrap_or(Value::Null),
            _ => return Ok(Value::Null),
        };
    }
    Ok(current)
}

fn fetch(name: &str, state: &State, attrs: &State) -> Eval<Value> {
    if let Some(value) = attrs.get(name) {
        return Ok(value.clone());
    }
    if let Some(value) = state.get(name) {
        return Ok(value.clone());
    }
    Err(format!(
        "cannot resolve {:?} \u{2014} no such attribute or argument",
        name
    ))
}

pub fn numeric_value(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

pub fn require_number(value: &Value, operation: &str) -> Eval<f64> {
    numeric_value(value)
        .ok_or_else(|| format!("{} expects a number, got {}", operation, describe(value)))
}

pub fn describe(value: &Value) -> String {
    match value {
        Value::Null => "nil".to_string(),
        Value::String(text) => format!("{:?}", text),
        Value::Number(n) => match n.as_i64() {
            Some(i) => i.to_string(),
            None => format_float(n.as_f64().unwrap_or(0.0)),
        },
        other => other.to_string(),
    }
}

pub fn class_of(value: &Value) -> String {
    match value {
        Value::Null => "nil".to_string(),
        Value::Bool(true) => "TrueClass".to_string(),
        Value::Bool(false) => "FalseClass".to_string(),
        Value::String(_) => "String".to_string(),
        Value::Array(_) => "Array".to_string(),
        Value::Object(_) => "Hash".to_string(),
        Value::Number(n) => {
            if n.is_i64() || n.is_u64() {
                "Integer".to_string()
            } else {
                "Float".to_string()
            }
        }
    }
}

fn format_float(value: f64) -> String {
    if value.fract() == 0.0 {
        format!("{:.1}", value)
    } else {
        value.to_string()
    }
}
