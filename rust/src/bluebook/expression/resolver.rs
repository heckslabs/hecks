use serde_json::{Map, Value};

pub type State = Map<String, Value>;

pub type Eval<T> = Result<T, String>;

const SIGN_TESTS: [&str; 3] = ["positive?", "negative?", "zero?"];

pub fn resolve_expr(expr: &str, state: &State, attrs: &State) -> Eval<Value> {
    let expr = expr.trim();

    if let Some(field) = expr.strip_suffix(".length") {
        return resolve_expr(&format!("{}.size", field.trim()), state, attrs);
    }

    if let Ok(n) = expr.parse::<i64>() {
        return Ok(Value::from(n));
    }
    if let Ok(f) = expr.parse::<f64>() {
        return Ok(Value::from(f));
    }
    if is_quoted(expr) {
        return Ok(Value::String(expr[1..expr.len() - 1].to_string()));
    }
    match expr {
        "true" => return Ok(Value::Bool(true)),
        "false" => return Ok(Value::Bool(false)),
        "nil" | "null" => return Ok(Value::Null),
        _ => {}
    }

    if let Some((left, right)) = split_addition(expr) {
        let left = require_number(&resolve_expr(&left, state, attrs)?, "addition")?;
        let right = require_number(&resolve_expr(&right, state, attrs)?, "addition")?;
        return Ok(Value::from(left + right));
    }

    for test in SIGN_TESTS {
        if let Some(receiver) = expr.strip_suffix(&format!(".{}", test)) {
            return apply_sign_test(receiver, test, state, attrs);
        }
    }

    if let Some((receiver, argument)) = match_call(expr, ".modulo(") {
        return apply_modulo(&receiver, &argument, state, attrs);
    }

    if let Some(receiver) = expr.strip_suffix(".empty?") {
        return emptiness_of(receiver.trim(), state, attrs);
    }

    if let Some(receiver) = expr.strip_suffix(".to_s") {
        return string_of(receiver.trim(), state, attrs);
    }

    if let Some(receiver) = expr.strip_suffix(".size") {
        return size_of(receiver.trim(), state, attrs);
    }

    lookup(expr, state, attrs)
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

fn size_of(receiver: &str, state: &State, attrs: &State) -> Eval<Value> {
    let value = resolve_expr(receiver, state, attrs)?;

    match &value {
        Value::Array(items) => Ok(Value::from(items.len() as i64)),
        Value::String(text) => Ok(Value::from(text.chars().count() as i64)),
        Value::Object(map) => Ok(Value::from(map.len() as i64)),
        other => Err(format!(
            "size expects a list or string, got {}",
            describe(other)
        )),
    }
}

fn emptiness_of(receiver: &str, state: &State, attrs: &State) -> Eval<Value> {
    let value = resolve_expr(receiver, state, attrs)?;

    match &value {
        Value::Array(items) => Ok(Value::Bool(items.is_empty())),
        Value::String(text) => Ok(Value::Bool(text.is_empty())),
        Value::Object(map) => Ok(Value::Bool(map.is_empty())),
        other => Err(format!(
            "empty? expects a list or string, got {}",
            describe(other)
        )),
    }
}

fn string_of(receiver: &str, state: &State, attrs: &State) -> Eval<Value> {
    let value = resolve_expr(receiver, state, attrs)?;

    Ok(Value::String(match &value {
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

fn apply_sign_test(receiver: &str, test: &str, state: &State, attrs: &State) -> Eval<Value> {
    let value = resolve_expr(receiver, state, attrs)?;
    let number = numeric_value(&value)
        .ok_or_else(|| format!("{} expects a number, got {}", test, describe(&value)))?;

    Ok(Value::Bool(match test {
        "positive?" => number > 0.0,
        "negative?" => number < 0.0,
        _ => number == 0.0,
    }))
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

fn apply_modulo(receiver: &str, argument: &str, state: &State, attrs: &State) -> Eval<Value> {
    let divisor = require_number(&resolve_expr(argument, state, attrs)?, "modulo")?;
    if divisor == 0.0 {
        return Err("divided by 0".to_string());
    }
    let left = require_number(&resolve_expr(receiver, state, attrs)?, "modulo")?;

    Ok(Value::from((left as i64).rem_euclid(divisor as i64)))
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
